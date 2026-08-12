import AppKit
import CoreGraphics
import ImageIO
import Metal

/// One linear Display P3 `RGBA16Float` texture per app.
///
/// The source icon is rasterized at 4x the selected display size, converted by ColorSync while drawing
/// into an extended-linear Display P3 context, and premultiplied there. Metal
/// therefore receives linear premultiplied values and never has to divide RGB by
/// a nearly-zero edge alpha.
final class IconTextureStore: @unchecked Sendable {
    private struct CacheKey: Hashable {
        let appID: String
        let pixelSize: Int
    }

    private let device: MTLDevice
    private let iconCache = AppIconCache()
    private let cacheLock = NSLock()
    private var cache: [CacheKey: MTLTexture] = [:]

    /// Keep four source pixels for each display point. The 128pt layouts use
    /// 512px textures; the 256pt layout uses 1024px textures.
    private var pixelSize = Int(GridLayoutPreset.current.iconPointSize * 4)
    private let bytesPerComponent = MemoryLayout<Float16>.size

    private static let linearDisplayP3 = CGColorSpace(
        name: CGColorSpace.extendedLinearDisplayP3
    )!

    init(device: MTLDevice) {
        self.device = device
    }

    /// Switch texture resolution when the user changes the grid preset. The
    /// old textures cannot be reused because their rasterization size differs.
    func configure(for preset: GridLayoutPreset) {
        let requestedPixelSize = Int(preset.iconPointSize * 4)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard pixelSize != requestedPixelSize else { return }
        pixelSize = requestedPixelSize
        cache.removeAll(keepingCapacity: true)
    }

    func clear() {
        cacheLock.lock()
        cache.removeAll(keepingCapacity: true)
        cacheLock.unlock()
    }

    func rebuild(with apps: [AppInfo]) {
        let ids = Set(apps.map(\.id))
        cacheLock.lock()
        defer { cacheLock.unlock() }
        for key in cache.keys where !ids.contains(key.appID) {
            cache.removeValue(forKey: key)
        }
    }

    func texture(for app: AppInfo) -> MTLTexture? {
        cacheLock.lock()
        let requestedPixelSize = pixelSize
        let key = CacheKey(appID: app.id, pixelSize: requestedPixelSize)
        if let existing = cache[key] {
            cacheLock.unlock()
            return existing
        }
        cacheLock.unlock()

        guard let texture = makeLinearDisplayP3Texture(
            for: app,
            pixelSize: requestedPixelSize
        ) else { return nil }

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = cache[key] { return existing }
        cache[key] = texture
        return texture
    }

    private func makeLinearDisplayP3Texture(
        for app: AppInfo,
        pixelSize px: Int
    ) -> MTLTexture? {
        let bytesPerRow = px * 4 * bytesPerComponent
        let bitmapInfo = CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: px,
            height: px,
            bitsPerComponent: 16,
            bytesPerRow: bytesPerRow,
            space: Self.linearDisplayP3,
            bitmapInfo: bitmapInfo
        ), let data = context.data else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: px, height: px))
        let image = iconCache.image(for: app, size: CGFloat(px))

        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: px, height: px),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: px,
            height: px,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, px, px),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return texture
    }
}

typealias IconAtlas = IconTextureStore

/// The textured backing plate used by folder previews.
///
/// The source PNGs are premultiplied while being rasterized so they can use the
/// same `sourceRGB = one` blending setup as app icons and text. Keep both
/// resolutions in a tiny cache and select the source that matches the current
/// grid preset.
final class FolderPadTextureStore {
    private let device: MTLDevice
    private var cache: [GridLayoutPreset: MTLTexture] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func texture(for preset: GridLayoutPreset) -> MTLTexture? {
        if let texture = cache[preset] {
            return texture
        }

        let resourceName: String
        switch preset {
        case .fourByTwo:
            resourceName = "glass-pad-1024"
        case .fiveByFour, .sixByFour, .sevenByFive:
            resourceName = "glass-pad-512"
        }

        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
              let texture = makeTexture(from: url) else {
            return nil
        }
        cache[preset] = texture
        return texture
    }

    private func makeTexture(from url: URL) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        pixels.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        texture.label = "QLaunchpad folder pad"
        return texture
    }
}
