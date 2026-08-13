import AppKit
import CoreGraphics
import ImageIO
import Metal

private var iconTextureRasterScale: CGFloat {
    IconRenderQuality.current.rasterScale
}

/// One linear Display P3 texture per app.
///
/// - **Quality:** `RGBA16Float`, 4× raster.
/// - **Performance:** linear Display P3 quantized to `RGBA8Unorm`, 2× raster.
/// - **Low memory:** same 2× RGBA8 bake as performance (residency is page-windowed).
final class IconTextureStore: @unchecked Sendable {
    private struct CacheKey: Hashable {
        let appID: String
        let pixelSize: Int
        /// Avoid reusing a texture when quality/format flips at the same size.
        let quality: String
    }

    private let device: MTLDevice
    private let iconCache = AppIconCache()
    private let cacheLock = NSLock()
    private var cache: [CacheKey: MTLTexture] = [:]
    /// In-flight background bakes (appID|quality|pixelSize).
    private var inflightBakes = Set<String>()
    /// When non-nil, only these app IDs may be baked or retained (page window).
    private var allowedAppIDs: Set<String>?
    // Serial: NSGraphicsContext / CG drawing is not safe across concurrent workers.
    private let bakeQueue = DispatchQueue(
        label: "com.qzrzz.qlaunchpad.icon-bake",
        qos: .userInitiated
    )
    private let bakeNotifyQueue = DispatchQueue(label: "com.qzrzz.qlaunchpad.icon-bake.notify")
    private var bakeNotifyScheduled = false

    private var pixelSize = Int(
        GridLayoutPreset.current.iconPointSize * IconRenderQuality.current.rasterScale
    )
    private var cachedQualityRaw = IconRenderQuality.current.rawValue

    private static let linearDisplayP3 = CGColorSpace(
        name: CGColorSpace.extendedLinearDisplayP3
    )!

    init(device: MTLDevice) {
        self.device = device
    }

    /// Switch texture resolution when the grid preset or render quality changes.
    func configure(for preset: GridLayoutPreset) {
        let quality = IconRenderQuality.current
        let requestedPixelSize = Int(preset.iconPointSize * quality.rasterScale)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard pixelSize != requestedPixelSize || cachedQualityRaw != quality.rawValue else {
            return
        }
        pixelSize = requestedPixelSize
        cachedQualityRaw = quality.rawValue
        cache.removeAll(keepingCapacity: true)
    }

    /// Drop all cached textures and sync pixel size to the active quality/layout.
    func resetForRenderQualityChange() {
        let quality = IconRenderQuality.current
        let requestedPixelSize = Int(
            GridLayoutPreset.current.iconPointSize * quality.rasterScale
        )
        cacheLock.lock()
        pixelSize = requestedPixelSize
        cachedQualityRaw = quality.rawValue
        cache.removeAll(keepingCapacity: true)
        cacheLock.unlock()
    }

    func clear() {
        cacheLock.lock()
        cache.removeAll(keepingCapacity: true)
        inflightBakes.removeAll(keepingCapacity: true)
        allowedAppIDs = nil
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

    /// Restrict which apps may be baked/kept. Pass `nil` only for unrestricted tools.
    func setAllowedAppIDs(_ ids: Set<String>?) {
        cacheLock.lock()
        allowedAppIDs = ids
        cacheLock.unlock()
    }

    /// Expand the bake allow-list without dropping already-cached textures.
    func expandAllowedAppIDs(_ ids: Set<String>) {
        cacheLock.lock()
        if let existing = allowedAppIDs {
            allowedAppIDs = existing.union(ids)
        } else {
            allowedAppIDs = ids
        }
        cacheLock.unlock()
    }

    /// Drop GPU textures whose app IDs are outside the active page window.
    func retainOnly(appIDs: Set<String>) {
        cacheLock.lock()
        allowedAppIDs = appIDs
        for key in cache.keys where !appIDs.contains(key.appID) {
            cache.removeValue(forKey: key)
        }
        // Drop stale in-flight work for apps that left the window.
        inflightBakes = inflightBakes.filter { token in
            let appID = token.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            return appIDs.contains(appID)
        }
        cacheLock.unlock()
    }

    var cachedTextureCount: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.count
    }

    /// - Parameter allowCreate: When `false`, never rasterize on the caller
    ///   thread (used by the Metal draw loop). A background bake is enqueued
    ///   instead so scrolling stays smooth.
    func texture(for app: AppInfo, allowCreate: Bool = true) -> MTLTexture? {
        let quality = IconRenderQuality.current
        let requestedPixelSize = Int(
            GridLayoutPreset.current.iconPointSize * quality.rasterScale
        )
        cacheLock.lock()
        if pixelSize != requestedPixelSize || cachedQualityRaw != quality.rawValue {
            pixelSize = requestedPixelSize
            cachedQualityRaw = quality.rawValue
            cache.removeAll(keepingCapacity: true)
            inflightBakes.removeAll(keepingCapacity: true)
        }
        let key = CacheKey(
            appID: app.id,
            pixelSize: requestedPixelSize,
            quality: quality.rawValue
        )
        if let existing = cache[key] {
            cacheLock.unlock()
            return existing
        }
        cacheLock.unlock()

        if !allowCreate {
            enqueueBake(app: app, pixelSize: requestedPixelSize, quality: quality)
            return nil
        }

        cacheLock.lock()
        if let allowed = allowedAppIDs, !allowed.contains(app.id) {
            cacheLock.unlock()
            return nil
        }
        cacheLock.unlock()

        return bakeAndStore(app: app, pixelSize: requestedPixelSize, quality: quality)
    }

    private func bakeKey(appID: String, pixelSize: Int, quality: String) -> String {
        "\(appID)|\(quality)|\(pixelSize)"
    }

    private func enqueueBake(app: AppInfo, pixelSize: Int, quality: IconRenderQuality) {
        let flight = bakeKey(appID: app.id, pixelSize: pixelSize, quality: quality.rawValue)
        cacheLock.lock()
        if let allowed = allowedAppIDs, !allowed.contains(app.id) {
            cacheLock.unlock()
            return
        }
        if inflightBakes.contains(flight)
            || cache[CacheKey(appID: app.id, pixelSize: pixelSize, quality: quality.rawValue)] != nil {
            cacheLock.unlock()
            return
        }
        inflightBakes.insert(flight)
        cacheLock.unlock()

        bakeQueue.async { [weak self] in
            guard let self else { return }
            // Re-check allow-list after queueing — page may have moved on.
            self.cacheLock.lock()
            let stillAllowed = self.allowedAppIDs?.contains(app.id) ?? true
            self.cacheLock.unlock()
            if stillAllowed {
                _ = self.bakeAndStore(app: app, pixelSize: pixelSize, quality: quality)
            }
            self.cacheLock.lock()
            self.inflightBakes.remove(flight)
            self.cacheLock.unlock()
            if stillAllowed {
                self.scheduleBakeNotification()
            }
        }
    }

    private func scheduleBakeNotification() {
        bakeNotifyQueue.async {
            guard !self.bakeNotifyScheduled else { return }
            self.bakeNotifyScheduled = true
            // Coalesce many finished bakes into one main-thread redraw.
            self.bakeNotifyQueue.asyncAfter(deadline: .now() + 0.016) {
                self.bakeNotifyScheduled = false
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .qlaunchpadIconTexturesUpdated,
                        object: nil
                    )
                }
            }
        }
    }

    @discardableResult
    private func bakeAndStore(
        app: AppInfo,
        pixelSize requestedPixelSize: Int,
        quality: IconRenderQuality
    ) -> MTLTexture? {
        guard let texture = makeTexture(
            for: app,
            pixelSize: requestedPixelSize,
            quality: quality
        ) else { return nil }

        let key = CacheKey(
            appID: app.id,
            pixelSize: requestedPixelSize,
            quality: quality.rawValue
        )
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if pixelSize != requestedPixelSize || cachedQualityRaw != quality.rawValue {
            return nil
        }
        if let existing = cache[key] { return existing }
        cache[key] = texture
        return texture
    }

    private func makeTexture(
        for app: AppInfo,
        pixelSize px: Int,
        quality: IconRenderQuality
    ) -> MTLTexture? {
        switch quality {
        case .quality:
            return makeLinearFloat16Texture(for: app, pixelSize: px)
        case .performance, .lowMemory:
            return makeLinearUNorm8Texture(for: app, pixelSize: px)
        }
    }

    // MARK: Shared linear Display P3 raster

    /// Rasterize into linear extended Display P3 float16 (same ColorSync path
    /// for both quality modes). Caller owns the returned context buffer.
    private func makeLinearFloat16Context(
        pixelSize px: Int
    ) -> (context: CGContext, data: UnsafeMutableRawPointer, bytesPerRow: Int)? {
        let bytesPerComponent = MemoryLayout<Float16>.size
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
        return (context, data, bytesPerRow)
    }

    // MARK: Quality — RGBA16Float

    private func makeLinearFloat16Texture(
        for app: AppInfo,
        pixelSize px: Int
    ) -> MTLTexture? {
        guard let raster = makeLinearFloat16Context(pixelSize: px) else { return nil }
        drawIcon(app: app, into: raster.context, pixelSize: px)

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
            withBytes: raster.data,
            bytesPerRow: raster.bytesPerRow
        )
        return texture
    }

    // MARK: Performance — linear Display P3 quantized to RGBA8Unorm

    private func makeLinearUNorm8Texture(
        for app: AppInfo,
        pixelSize px: Int
    ) -> MTLTexture? {
        guard let raster = makeLinearFloat16Context(pixelSize: px) else { return nil }
        drawIcon(app: app, into: raster.context, pixelSize: px)

        let pixelCount = px * px
        var unorm = [UInt8](repeating: 0, count: pixelCount * 4)
        raster.data.withMemoryRebound(to: Float16.self, capacity: pixelCount * 4) { src in
            for i in 0..<(pixelCount * 4) {
                // Linear light, same domain as the float16 drawable. Clamp
                // extended-range peaks so 8-bit storage stays valid.
                let x = Float(src[i])
                let y = min(max(x, 0), 1)
                unorm[i] = UInt8(y * 255.0 + 0.5)
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: px,
            height: px,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        unorm.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, px, px),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: px * 4
            )
        }
        return texture
    }

    private func drawIcon(app: AppInfo, into context: CGContext, pixelSize px: Int) {
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
        let quality: String
    }

    private let device: MTLDevice
    private let iconCache = AppIconCache()
    private var cache: [CacheKey: MTLTexture] = [:]
    private var backgroundCache: [String: MTLTexture] = [:]

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

    /// Keep only the listed folder textures (plus shared backgrounds).
    func retainOnly(folderIDs: Set<String>) {
        for key in cache.keys where !folderIDs.contains(key.folderID) {
            cache.removeValue(forKey: key)
        }
    }

    func backgroundTexture(for preset: GridLayoutPreset) -> MTLTexture? {
        let quality = IconRenderQuality.current
        let pixelSize = Int(preset.iconPointSize * quality.rasterScale)
        let key = "\(quality.rawValue)|\(pixelSize)"
        if let texture = backgroundCache[key] { return texture }
        guard let padImage = padImage(for: preset),
              let texture = makeTexture(
                padImage: padImage,
                members: [],
                pixelSize: pixelSize,
                iconPointSize: preset.iconPointSize,
                quality: quality
              ) else { return nil }
        backgroundCache[key] = texture
        return texture
    }

    func texture(
        for folder: AppFolder,
        members: [AppInfo],
        preset: GridLayoutPreset,
        allowCreate: Bool = true
    ) -> MTLTexture? {
        let quality = IconRenderQuality.current
        let previewMembers = Array(members.prefix(9))
        guard !previewMembers.isEmpty else { return nil }
        let pixelSize = Int(preset.iconPointSize * quality.rasterScale)
        let key = CacheKey(
            folderID: folder.id,
            appIDs: previewMembers.map(\.id),
            pixelSize: pixelSize,
            quality: quality.rawValue
        )
        if let texture = cache[key] { return texture }
        // Folder composites are rarer; never block the draw loop on a miss.
        guard allowCreate else { return nil }

        guard let padImage = padImage(for: preset),
              let texture = makeTexture(
                padImage: padImage,
                members: previewMembers,
                pixelSize: pixelSize,
                iconPointSize: preset.iconPointSize,
                quality: quality
              ) else {
            return nil
        }
        for oldKey in cache.keys where oldKey.folderID == folder.id && oldKey != key {
            cache.removeValue(forKey: oldKey)
        }
        cache[key] = texture
        return texture
    }

    private func padImage(for preset: GridLayoutPreset) -> CGImage? {
        let pixelSize = Int(preset.iconPointSize * iconTextureRasterScale)
        let resourceName = pixelSize > 512 ? "glass-pad-1024" : "glass-pad-512"
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image
    }

    private func makeTexture(
        padImage: CGImage,
        members: [AppInfo],
        pixelSize px: Int,
        iconPointSize: CGFloat,
        quality: IconRenderQuality
    ) -> MTLTexture? {
        switch quality {
        case .quality:
            return makeLinearFloat16Texture(
                padImage: padImage,
                members: members,
                pixelSize: px,
                iconPointSize: iconPointSize
            )
        case .performance, .lowMemory:
            return makeLinearUNorm8Texture(
                padImage: padImage,
                members: members,
                pixelSize: px,
                iconPointSize: iconPointSize
            )
        }
    }

    private func makeLinearFloat16Context(
        pixelSize px: Int
    ) -> (context: CGContext, data: UnsafeMutableRawPointer, bytesPerRow: Int)? {
        let bytesPerComponent = MemoryLayout<Float16>.size
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
        return (context, data, bytesPerRow)
    }

    private func makeLinearFloat16Texture(
        padImage: CGImage,
        members: [AppInfo],
        pixelSize px: Int,
        iconPointSize: CGFloat
    ) -> MTLTexture? {
        guard let raster = makeLinearFloat16Context(pixelSize: px) else { return nil }
        composeFolder(
            padImage: padImage,
            members: members,
            into: raster.context,
            pixelSize: px,
            iconPointSize: iconPointSize
        )

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
            withBytes: raster.data,
            bytesPerRow: raster.bytesPerRow
        )
        texture.label = "QLaunch folder icon"
        return texture
    }

    private func makeLinearUNorm8Texture(
        padImage: CGImage,
        members: [AppInfo],
        pixelSize px: Int,
        iconPointSize: CGFloat
    ) -> MTLTexture? {
        guard let raster = makeLinearFloat16Context(pixelSize: px) else { return nil }
        composeFolder(
            padImage: padImage,
            members: members,
            into: raster.context,
            pixelSize: px,
            iconPointSize: iconPointSize
        )

        let pixelCount = px * px
        var unorm = [UInt8](repeating: 0, count: pixelCount * 4)
        raster.data.withMemoryRebound(to: Float16.self, capacity: pixelCount * 4) { src in
            for i in 0..<(pixelCount * 4) {
                let x = Float(src[i])
                let y = min(max(x, 0), 1)
                unorm[i] = UInt8(y * 255.0 + 0.5)
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: px,
            height: px,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        unorm.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, px, px),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: px * 4
            )
        }
        texture.label = "QLaunch folder icon"
        return texture
    }

    private func composeFolder(
        padImage: CGImage,
        members: [AppInfo],
        into context: CGContext,
        pixelSize px: Int,
        iconPointSize: CGFloat
    ) {
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
    }
}
