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

/// A folder preview flattened into one icon texture.
///
/// Folder membership is part of the cache key, so adding, removing, or
/// reordering an app automatically rasterizes a new preview. Once created, the
/// renderer can treat this exactly like an application icon and apply the same
/// entrance, zoom, drag, and opacity animations to the whole image.
final class FolderIconTextureStore {
    private struct CacheKey: Hashable {
        let folderID: String
        let appIDs: [String]
        let pixelSize: Int
    }

    private let device: MTLDevice
    private let iconCache = AppIconCache()
    private var cache: [CacheKey: MTLTexture] = [:]
    private var backgroundCache: [Int: MTLTexture] = [:]
    private let bytesPerComponent = MemoryLayout<Float16>.size

    private static let linearDisplayP3 = CGColorSpace(
        name: CGColorSpace.extendedLinearDisplayP3
    )!

    init(device: MTLDevice) {
        self.device = device
    }

    func clear() {
        cache.removeAll(keepingCapacity: true)
        backgroundCache.removeAll(keepingCapacity: true)
    }

    func backgroundTexture(for preset: GridLayoutPreset) -> MTLTexture? {
        let pixelSize = Int(preset.iconPointSize * 4)
        if let texture = backgroundCache[pixelSize] { return texture }
        guard let padImage = padImage(for: preset),
              let texture = makeTexture(
                padImage: padImage,
                members: [],
                pixelSize: pixelSize,
                iconPointSize: preset.iconPointSize
              ) else { return nil }
        backgroundCache[pixelSize] = texture
        return texture
    }

    func texture(
        for folder: AppFolder,
        members: [AppInfo],
        preset: GridLayoutPreset
    ) -> MTLTexture? {
        let previewMembers = Array(members.prefix(9))
        guard !previewMembers.isEmpty else { return nil }
        let pixelSize = Int(preset.iconPointSize * 4)
        let key = CacheKey(
            folderID: folder.id,
            appIDs: previewMembers.map(\.id),
            pixelSize: pixelSize
        )
        if let texture = cache[key] { return texture }

        guard let padImage = padImage(for: preset),
              let texture = makeTexture(
                padImage: padImage,
                members: previewMembers,
                pixelSize: pixelSize,
                iconPointSize: preset.iconPointSize
              ) else {
            return nil
        }
        // Discard obsolete membership variants for this folder while retaining
        // previews belonging to every other folder.
        for oldKey in cache.keys where oldKey.folderID == folder.id && oldKey != key {
            cache.removeValue(forKey: oldKey)
        }
        cache[key] = texture
        return texture
    }

    private func padImage(for preset: GridLayoutPreset) -> CGImage? {
        let resourceName: String
        switch preset {
        case .fourByTwo:
            resourceName = "glass-pad-1024"
        case .fiveByFour, .sixByFour, .sevenByFive:
            resourceName = "glass-pad-512"
        }

        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image
    }

    private func makeTexture(
        padImage: CGImage,
        members: [AppInfo],
        pixelSize px: Int,
        iconPointSize: CGFloat
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
        ), let data = context.data else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: px, height: px))
        context.interpolationQuality = .high
        context.draw(padImage, in: CGRect(x: 0, y: 0, width: px, height: px))

        let pointsToPixels = CGFloat(px) / iconPointSize
        let miniSize = 22 * pointsToPixels
        let gap = 4 * pointsToPixels
        let contentSize = miniSize * 3 + gap * 2
        let left = (CGFloat(px) - contentSize) * 0.5
        let bottom = (CGFloat(px) - contentSize) * 0.5

        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        for (index, app) in members.enumerated() {
            let column = index % 3
            // CGContext is bottom-up; invert the visual row so the first member
            // remains at the preview's top-left corner.
            let rowFromBottom = 2 - index / 3
            let rect = NSRect(
                x: left + CGFloat(column) * (miniSize + gap),
                y: bottom + CGFloat(rowFromBottom) * (miniSize + gap),
                width: miniSize,
                height: miniSize
            )
            iconCache.image(for: app, size: miniSize).draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: px,
            height: px,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, px, px),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        texture.label = "QLaunchpad folder icon"
        return texture
    }
}
