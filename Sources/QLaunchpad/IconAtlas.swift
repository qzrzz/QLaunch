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
/// - **Performance:** same linear bake, packed as `RGBA8Unorm_srgb`, 2× raster.
/// - **Low memory:** same 2× sRGB8 bake as performance (residency is page-windowed).
///
/// 8-bit modes store `sRGB(premul)` in `RGBA8Unorm_srgb` so sampling returns
/// linear light (no dark posterization). The shader then converts to
/// `sRGB(C)*a` before presenting into a non-sRGB Display P3 drawable —
/// an sRGB framebuffer would encode `sRGB(C*a)` and harden icon AA.
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

    /// Cache-only lookup for the Metal draw loop. Resource prewarming owns all
    /// production so rendering never starts a second CoreGraphics worker.
    func cachedTexture(for app: AppInfo) -> MTLTexture? {
        let quality = IconRenderQuality.current
        let requestedPixelSize = Int(
            GridLayoutPreset.current.iconPointSize * quality.rasterScale
        )
        let key = CacheKey(
            appID: app.id,
            pixelSize: requestedPixelSize,
            quality: quality.rawValue
        )
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard pixelSize == requestedPixelSize, cachedQualityRaw == quality.rawValue else {
            return nil
        }
        return cache[key]
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

        let flight = bakeKey(
            appID: app.id,
            pixelSize: requestedPixelSize,
            quality: quality.rawValue
        )
        cacheLock.lock()
        if let allowed = allowedAppIDs, !allowed.contains(app.id) {
            cacheLock.unlock()
            return nil
        }
        if let existing = cache[key] {
            cacheLock.unlock()
            return existing
        }
        // The draw path may have enqueued the same miss immediately before a
        // resident prewarm task reaches it. Let the first producer own the bake
        // so opening a window never doubles the expensive icon raster work.
        if inflightBakes.contains(flight) {
            cacheLock.unlock()
            return nil
        }
        inflightBakes.insert(flight)
        cacheLock.unlock()

        let texture = bakeAndStore(app: app, pixelSize: requestedPixelSize, quality: quality)
        cacheLock.lock()
        inflightBakes.remove(flight)
        cacheLock.unlock()
        return texture
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

    // MARK: Performance — linear Display P3 packed as RGBA8Unorm_srgb

    private func makeLinearUNorm8Texture(
        for app: AppInfo,
        pixelSize px: Int
    ) -> MTLTexture? {
        guard let raster = makeLinearFloat16Context(pixelSize: px) else { return nil }
        drawIcon(app: app, into: raster.context, pixelSize: px)
        return makeSRGBUNorm8Texture(device: device, float16: raster.data, pixelSize: px)
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
final class FolderIconTextureStore: @unchecked Sendable {
    private struct CacheKey: Hashable {
        let folderID: String
        let appIDs: [String]
        let pixelSize: Int
        let quality: String
    }

    private let device: MTLDevice
    private let iconCache = AppIconCache()
    private let cacheLock = NSLock()
    private let bakeLock = NSLock()
    private var cache: [CacheKey: MTLTexture] = [:]
    private var backgroundCache: [String: MTLTexture] = [:]
    /// Generation-tagged producers prevent a bake invalidated by `clear()` from
    /// removing or overwriting a newer producer for the same folder key.
    private var inflightBakes: [CacheKey: UInt64] = [:]
    private var cacheGeneration: UInt64 = 0
    private var allowedFolderIDs: Set<String>?

    private static let linearDisplayP3 = CGColorSpace(
        name: CGColorSpace.extendedLinearDisplayP3
    )!

    init(device: MTLDevice) {
        self.device = device
    }

    func clear() {
        cacheLock.lock()
        cacheGeneration &+= 1
        cache.removeAll(keepingCapacity: true)
        backgroundCache.removeAll(keepingCapacity: true)
        inflightBakes.removeAll(keepingCapacity: true)
        allowedFolderIDs = nil
        cacheLock.unlock()
    }

    func setAllowedFolderIDs(_ ids: Set<String>?) {
        cacheLock.lock()
        allowedFolderIDs = ids
        cacheLock.unlock()
    }

    func expandAllowedFolderIDs(_ ids: Set<String>) {
        cacheLock.lock()
        if let existing = allowedFolderIDs {
            allowedFolderIDs = existing.union(ids)
        } else {
            allowedFolderIDs = ids
        }
        cacheLock.unlock()
    }

    /// Keep only the listed folder textures (plus shared backgrounds).
    func retainOnly(folderIDs: Set<String>) {
        cacheLock.lock()
        allowedFolderIDs = folderIDs
        for key in cache.keys where !folderIDs.contains(key.folderID) {
            cache.removeValue(forKey: key)
        }
        cacheLock.unlock()
    }

    func backgroundTexture(for preset: GridLayoutPreset) -> MTLTexture? {
        let quality = IconRenderQuality.current
        let pixelSize = Int(preset.iconPointSize * quality.rasterScale)
        let key = "\(quality.rawValue)|\(pixelSize)"
        cacheLock.lock()
        if let texture = backgroundCache[key] {
            cacheLock.unlock()
            return texture
        }
        let generation = cacheGeneration
        cacheLock.unlock()
        bakeLock.lock()
        let built: MTLTexture?
        if let padImage = padImage(for: preset) {
            built = makeTexture(
                padImage: padImage,
                members: [],
                pixelSize: pixelSize,
                iconPointSize: preset.iconPointSize,
                quality: quality
            )
        } else {
            built = nil
        }
        bakeLock.unlock()
        guard let texture = built else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cacheGeneration == generation else { return nil }
        if let existing = backgroundCache[key] { return existing }
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
        cacheLock.lock()
        if let texture = cache[key] {
            cacheLock.unlock()
            return texture
        }
        // Folder composites are rarer; never block the draw loop on a miss.
        guard allowCreate,
              allowedFolderIDs?.contains(folder.id) ?? true else {
            cacheLock.unlock()
            return nil
        }
        let generation = cacheGeneration
        if inflightBakes[key] == generation {
            cacheLock.unlock()
            return nil
        }
        inflightBakes[key] = generation
        cacheLock.unlock()

        bakeLock.lock()
        let texture: MTLTexture?
        if let padImage = padImage(for: preset) {
            texture = makeTexture(
                padImage: padImage,
                members: previewMembers,
                pixelSize: pixelSize,
                iconPointSize: preset.iconPointSize,
                quality: quality
            )
        } else {
            texture = nil
        }
        bakeLock.unlock()
        cacheLock.lock()
        defer {
            if inflightBakes[key] == generation {
                inflightBakes.removeValue(forKey: key)
            }
            cacheLock.unlock()
        }
        guard let texture,
              cacheGeneration == generation,
              allowedFolderIDs?.contains(folder.id) ?? true else { return nil }
        if let existing = cache[key] { return existing }
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
        return makeSRGBUNorm8Texture(
            device: device,
            float16: raster.data,
            pixelSize: px,
            label: "QLaunch folder icon"
        )
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

/// Display P3 uses the sRGB OETF. Encode premultiplied linear RGB; leave
/// alpha linear. `rgba8Unorm_srgb` decodes RGB back to linear premul.
private func encodeLinearToSRGB8(_ linear: Float) -> UInt8 {
    let x = min(max(linear, 0), 1)
    let encoded: Float
    if x <= 0.0031308 {
        encoded = x * 12.92
    } else {
        encoded = 1.055 * pow(x, 1.0 / 2.4) - 0.055
    }
    return UInt8(encoded * 255.0 + 0.5)
}

private func makeSRGBUNorm8Texture(
    device: MTLDevice,
    float16 data: UnsafeMutableRawPointer,
    pixelSize px: Int,
    label: String? = nil
) -> MTLTexture? {
    let pixelCount = px * px
    var unorm = [UInt8](repeating: 0, count: pixelCount * 4)
    data.withMemoryRebound(to: Float16.self, capacity: pixelCount * 4) { src in
        var pixel = 0
        while pixel < pixelCount {
            let base = pixel * 4
            unorm[base]     = encodeLinearToSRGB8(Float(src[base]))
            unorm[base + 1] = encodeLinearToSRGB8(Float(src[base + 1]))
            unorm[base + 2] = encodeLinearToSRGB8(Float(src[base + 2]))
            let alpha = min(max(Float(src[base + 3]), 0), 1)
            unorm[base + 3] = UInt8(alpha * 255.0 + 0.5)
            pixel += 1
        }
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm_srgb,
        width: px,
        height: px,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    texture.label = label
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
