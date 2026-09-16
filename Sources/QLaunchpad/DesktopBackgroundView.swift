import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import ImageIO

private enum BackgroundVisualTokens {
    static let saturation: CGFloat = 1.16
    static let maximumLongEdge: CGFloat = 2_000
    static let tintAlpha: CGFloat = 0.18
    static let vignetteBottomAlpha: CGFloat = 0.28
    static let vignetteTopAlpha: CGFloat = 0.18
}

/// Best-effort bridge to WindowServer's private wallpaper capture SPI.
private enum PrivateWindowServerCapture {
    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias CaptureWindowList = @convention(c) (
        UInt32,
        UnsafePointer<CGWindowID>,
        UInt32,
        UInt32
    ) -> Unmanaged<CFArray>?

    private static let mainConnectionID: MainConnectionID? = symbol(
        "CGSMainConnectionID",
        as: MainConnectionID.self
    )
    private static let captureWindowList: CaptureWindowList? = symbol(
        "CGSHWCaptureWindowList",
        as: CaptureWindowList.self
    )

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(address, to: T.self)
    }

    static func capture(windowID: CGWindowID) -> CGImage? {
        guard let mainConnectionID, let captureWindowList else { return nil }

        // kCGSWindowCaptureNominalResolution | kCGSCaptureIgnoreGlobalClipShape
        let options: UInt32 = 0x0200 | 0x0800
        var id = windowID
        guard let result = captureWindowList(mainConnectionID(), &id, 1, options) else {
            return nil
        }

        let objects = result.takeRetainedValue() as NSArray
        guard let object = objects.firstObject else { return nil }
        return (object as! CGImage)
    }
}

private enum WallpaperWindowLocator {
    /// Desktop-sized wallpaper surfaces, best match first.
    /// Wallpaper lives at `desktopLevel - 1`. Window Server and Dock helpers
    /// capture black, so they are never candidates.
    static func candidates(for displayID: CGDirectDisplayID) -> [CGWindowID] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let displayBounds = CGDisplayBounds(displayID)
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        var bestByID: [CGWindowID: Double] = [:]

        for window in windows {
            guard
                let idNumber = window[kCGWindowNumber as String] as? NSNumber,
                let layerNumber = window[kCGWindowLayer as String] as? NSNumber,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let x = (bounds["X"] as? NSNumber)?.doubleValue,
                let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                abs(x - displayBounds.origin.x) < 1,
                abs(y - displayBounds.origin.y) < 1,
                abs(width - displayBounds.width) < 1,
                abs(height - displayBounds.height) < 1
            else {
                continue
            }

            let owner = (window[kCGWindowOwnerName as String] as? String ?? "")
                .lowercased()
            let name = (window[kCGWindowName as String] as? String ?? "")
                .lowercased()
            let layer = layerNumber.intValue
            guard let score = score(
                owner: owner,
                name: name,
                layer: layer,
                desktopLevel: desktopLevel
            ) else {
                continue
            }

            let id = idNumber.uint32Value
            if score > (bestByID[id] ?? -.greatestFiniteMagnitude) {
                bestByID[id] = score
            }
        }

        return bestByID.sorted { $0.value > $1.value }.map(\.key)
    }

    static func score(
        owner: String,
        name: String,
        layer: Int,
        desktopLevel: Int
    ) -> Double? {
        guard layer <= desktopLevel + 1 else { return nil }

        if owner == "windowmanager" && (name == "wallpaper" || name.isEmpty) {
            return 1_000
        }
        if owner.contains("wallpaper")
            || name == "wallpaper"
            || name.hasPrefix("desktop picture") {
            return 900
        }
        // Window Server and Dock helpers capture black.
        if owner == "window server" || owner == "dock" {
            return nil
        }
        // Tahoe can expose nonempty, renamed owner/name metadata for the real
        // wallpaper surface. After excluding black helpers, identify it by layer.
        if layer == desktopLevel - 1 {
            return 500
        }
        return nil
    }
}

/// User still-image path when CGS capture returns nothing usable.
private enum WallpaperFileSource {
    static func workspaceURL(for displayID: CGDirectDisplayID) -> URL? {
        let screen = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID
            return number == displayID
        }
        guard let url = screen.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }) else {
            return nil
        }
        return readableImageURL(url)
    }

    static func indexPlistURL(for displayID: CGDirectDisplayID) -> URL? {
        guard let uuid = displayUUIDString(displayID) else { return nil }
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard
            let root = NSDictionary(contentsOf: store),
            let displays = root["Displays"] as? [String: Any],
            let display = displays[uuid] as? [String: Any],
            let desktop = display["Desktop"] as? [String: Any],
            let content = desktop["Content"] as? [String: Any],
            let choices = content["Choices"] as? [[String: Any]],
            let choice = choices.first
        else {
            return nil
        }

        if let files = choice["Files"] as? [[String: Any]] {
            for file in files {
                if let parsed = url(fromPlistValue: file["relative"] ?? file["url"]),
                   let readable = readableImageURL(parsed) {
                    return readable
                }
            }
        }
        if let configData = choice["Configuration"] as? Data,
           let config = try? PropertyListSerialization.propertyList(
               from: configData,
               options: [],
               format: nil
           ) as? [String: Any],
           let parsed = url(fromPlistValue: config["url"]),
           let readable = readableImageURL(parsed) {
            return readable
        }
        return nil
    }

    static func loadCGImage(from url: URL, prefersDark: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let index = (count > 1 && prefersDark) ? 1 : 0
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, index, options)
    }

    private static func displayUUIDString(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func url(fromPlistValue value: Any?) -> URL? {
        if let relative = value as? String {
            return URL(string: relative)
        }
        if let dict = value as? [String: Any], let relative = dict["relative"] as? String {
            return URL(string: relative)
        }
        return nil
    }

    private static func readableImageURL(_ url: URL) -> URL? {
        guard !isPlaceholderStill(url) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private static func isPlaceholderStill(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name == "defaultdesktop.heic" || name == "defaultaerial.heic" {
            return true
        }
        if url.pathExtension.lowercased() == "madesktop" {
            return true
        }
        let path = url.standardizedFileURL.path.lowercased()
        return path.contains("/system/library/wallpapers/.default")
            || path.contains("/system/library/coreservices/defaultdesktop")
    }
}

private actor PrivateWallpaperRenderer {
    private let context = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: true
    ])

    func render(
        displayID: CGDirectDisplayID,
        backingScale _: CGFloat,
        blurRadius: CGFloat,
        saturation: CGFloat
    ) async -> CGImage? {
        guard let capturedImage = await captureWallpaperPixels(displayID: displayID) else {
            return nil
        }

        return render(
            image: capturedImage,
            blurRadius: blurRadius,
            saturation: saturation
        )
    }

    private func render(
        image: CGImage,
        blurRadius: CGFloat,
        saturation: CGFloat
    ) -> CGImage? {
        let input = CIImage(cgImage: image)
        let inputExtent = input.extent
        guard inputExtent.width > 0, inputExtent.height > 0 else { return nil }

        let scale = min(
            1,
            BackgroundVisualTokens.maximumLongEdge
                / max(inputExtent.width, inputExtent.height)
        )
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent

        let blurredImage: CIImage
        if blurRadius > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = scaled.clampedToExtent()
            blur.radius = Float(max(0.1, blurRadius * max(scale, 0.5)))
            blurredImage = blur.outputImage ?? scaled
        } else {
            blurredImage = scaled
        }

        let controls = CIFilter.colorControls()
        controls.inputImage = blurredImage
        controls.saturation = Float(saturation)
        controls.contrast = 1.02
        controls.brightness = 0

        guard let output = controls.outputImage?.cropped(to: scaledExtent) else {
            return nil
        }

        let outputRect = CGRect(
            x: 0,
            y: 0,
            width: max(1, scaledExtent.width),
            height: max(1, scaledExtent.height)
        )
        return context.createCGImage(output, from: outputRect)
    }

    func render(
        mode: LaunchpadBackgroundMode,
        customURL: URL?,
        blurRadius: CGFloat,
        displayID: CGDirectDisplayID,
        backingScale: CGFloat
    ) async -> CGImage? {
        switch mode {
        case .wallpaper:
            return await render(
                displayID: displayID,
                backingScale: backingScale,
                blurRadius: blurRadius,
                saturation: BackgroundVisualTokens.saturation
            )
        case .screen:
            return nil
        case .custom:
            guard let customURL,
                  let image = WallpaperFileSource.loadCGImage(
                      from: customURL,
                      prefersDark: false
                  ) else {
                return await render(
                    displayID: displayID,
                    backingScale: backingScale,
                    blurRadius: blurRadius,
                    saturation: BackgroundVisualTokens.saturation
                )
            }
            return render(
                image: image,
                blurRadius: blurRadius,
                saturation: BackgroundVisualTokens.saturation
            )
        }
    }

    private func captureWallpaperPixels(displayID: CGDirectDisplayID) async -> CGImage? {
        for windowID in WallpaperWindowLocator.candidates(for: displayID) {
            if let image = PrivateWindowServerCapture.capture(windowID: windowID),
               !isFailedBlackFrame(image) {
                return image
            }
        }

        let (workspaceURL, prefersDark) = await MainActor.run {
            (
                WallpaperFileSource.workspaceURL(for: displayID),
                NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            )
        }
        let fileURL = workspaceURL ?? WallpaperFileSource.indexPlistURL(for: displayID)
        if let fileURL,
           let image = WallpaperFileSource.loadCGImage(from: fileURL, prefersDark: prefersDark),
           !isFailedBlackFrame(image) {
            return image
        }
        return nil
    }

    /// Failed CGS captures are typically uniform black. Keep a previous good frame.
    func isFailedBlackFrame(_ image: CGImage) -> Bool {
        let width = 16
        let height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0
        var maxChannel = 0
        for index in 0..<(width * height) {
            let offset = index * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            sum += red + green + blue
            maxChannel = max(maxChannel, red, green, blue)
        }
        let average = Double(sum) / Double(width * height * 3)
        return average < 3 && maxChannel < 8
    }
}

@MainActor
final class DesktopBackgroundView: NSView {
    private let visualEffectView = NSVisualEffectView()
    private let wallpaperImageView = NSImageView()
    private let tintView = NSView()
    private let vignetteView = GradientVignetteView()
    private let renderer = PrivateWallpaperRenderer()
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = 0
    private var preparedScreenIdentifier: CGDirectDisplayID?

    init(screen _: NSScreen?) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Public fallback, hidden after a successful private capture.
        visualEffectView.material = .fullScreenUI
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.alphaValue = 1
        visualEffectView.wantsLayer = true
        visualEffectView.autoresizingMask = [.width, .height]
        addSubview(visualEffectView)

        wallpaperImageView.imageScaling = .scaleAxesIndependently
        wallpaperImageView.imageAlignment = .alignCenter
        wallpaperImageView.isHidden = true
        wallpaperImageView.autoresizingMask = [.width, .height]
        addSubview(wallpaperImageView)

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor(
            calibratedWhite: 0,
            alpha: BackgroundVisualTokens.tintAlpha
        ).cgColor
        tintView.autoresizingMask = [.width, .height]
        addSubview(tintView)

        vignetteView.autoresizingMask = [.width, .height]
        addSubview(vignetteView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        captureTask?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let screen = window?.screen ?? NSScreen.main else { return }
        prepare(for: screen)
    }

    override func layout() {
        super.layout()
        visualEffectView.frame = bounds
        wallpaperImageView.frame = bounds
        tintView.frame = bounds
        vignetteView.frame = bounds
        applyLiveBlurRadius()
    }

    func prepare(for screen: NSScreen) {
        startCapture(on: screen, replaceExisting: false)
    }

    /// Recapture after the panel is gone so the next open is fresh, not black.
    func refreshAfterHide() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        startCapture(on: screen, replaceExisting: true)
    }

    func reloadForPreferenceChange() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        startCapture(on: screen, replaceExisting: true)
    }

    func clearCacheAndReload() {
        captureGeneration += 1
        captureTask?.cancel()
        wallpaperImageView.image = nil
        wallpaperImageView.isHidden = true
        visualEffectView.isHidden = false
        preparedScreenIdentifier = nil

        if let screen = window?.screen ?? NSScreen.main {
            startCapture(on: screen, replaceExisting: true)
        }
    }

    /// - Parameter replaceExisting: `false` reuses a good cache (opening). `true`
    ///   recaptures in the background and only swaps if the new frame is valid.
    private func startCapture(on screen: NSScreen, replaceExisting: Bool) {
        let screenIdentifier = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
        let displayID = screenIdentifier ?? CGMainDisplayID()
        let screenChanged = preparedScreenIdentifier != screenIdentifier
        let mode = LaunchpadBackgroundPreferences.mode

        if mode == .screen {
            captureGeneration += 1
            captureTask?.cancel()
            captureTask = nil
            preparedScreenIdentifier = screenIdentifier
            wallpaperImageView.image = nil
            wallpaperImageView.isHidden = true
            visualEffectView.isHidden = false
            visualEffectView.state = .active
            visualEffectView.alphaValue = 1
            applyLiveBlurRadius()
            return
        }

        if screenChanged {
            preparedScreenIdentifier = screenIdentifier
            wallpaperImageView.image = nil
            wallpaperImageView.isHidden = true
            visualEffectView.isHidden = false
        } else if !replaceExisting, mode != .screen,
                  wallpaperImageView.image != nil || captureTask != nil {
            // Reuse either the cached image or an in-flight capture for this display.
            return
        }

        captureGeneration += 1
        let generation = captureGeneration
        captureTask?.cancel()

        let customURL = mode == .custom
            ? LaunchpadBackgroundPreferences.customImageURL
            : nil
        let blurRadius = LaunchpadBackgroundPreferences.blurAmount
        let backingScale = screen.backingScaleFactor
        let keepPrevious = wallpaperImageView.image != nil
        captureTask = Task { [weak self] in
            let image = await self?.renderer.render(
                mode: mode,
                customURL: customURL,
                blurRadius: blurRadius,
                displayID: displayID,
                backingScale: backingScale
            )

            guard !Task.isCancelled, let self else { return }
            guard generation == self.captureGeneration else { return }

            var accepted: CGImage?
            if let image {
                let isValid = mode == .custom
                    ? true
                    : !(await self.renderer.isFailedBlackFrame(image))
                if isValid {
                    accepted = image
                }
            }
            guard !Task.isCancelled else { return }
            guard generation == self.captureGeneration else { return }
            self.captureTask = nil

            if let accepted {
                self.wallpaperImageView.image = NSImage(
                    cgImage: accepted,
                    size: NSSize(width: accepted.width, height: accepted.height)
                )
                self.wallpaperImageView.isHidden = false
                self.visualEffectView.isHidden = true
                return
            }

            guard !keepPrevious else { return }
            self.wallpaperImageView.image = nil
            self.wallpaperImageView.isHidden = true
            self.visualEffectView.isHidden = false
            self.applyLiveBlurRadius()
        }
    }

    func prepareForPresentation() {
        layer?.removeAllAnimations()
        wallpaperImageView.layer?.removeAnimation(forKey: "wallpaperOpacity")
        visualEffectView.layer?.removeAnimation(forKey: "liveBlurOpacity")
        alphaValue = 0
        wallpaperImageView.alphaValue = 1
        visualEffectView.alphaValue = 1
    }

    func animateWallpaperIn(duration: CFTimeInterval = 0.64) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 1
        }
    }

    func showWallpaperImmediately() {
        layer?.removeAllAnimations()
        wallpaperImageView.layer?.removeAnimation(forKey: "wallpaperOpacity")
        visualEffectView.layer?.removeAnimation(forKey: "liveBlurOpacity")
        alphaValue = 1
        wallpaperImageView.alphaValue = 1
        visualEffectView.alphaValue = 1
        applyLiveBlurRadius()
    }

    private func applyLiveBlurRadius() {
        guard let layer = gaussianBlurLayer(in: visualEffectView.layer) else { return }
        layer.setValue(
            NSNumber(value: Double(LaunchpadBackgroundPreferences.blurAmount)),
            forKeyPath: "filters.gaussianBlur.inputRadius"
        )
    }

    private func gaussianBlurLayer(
        in layer: CALayer?
    ) -> CALayer? {
        guard let layer else { return nil }
        for candidate in layer.filters ?? [] {
            guard let filter = candidate as? NSObject,
                  filter.value(forKey: "name") as? String == "gaussianBlur" else {
                continue
            }
            return layer
        }
        for sublayer in layer.sublayers ?? [] {
            if let blurLayer = gaussianBlurLayer(in: sublayer) {
                return blurLayer
            }
        }
        return nil
    }
}

private final class GradientVignetteView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = [
            NSColor.black.withAlphaComponent(BackgroundVisualTokens.vignetteBottomAlpha).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(BackgroundVisualTokens.vignetteTopAlpha).cgColor
        ]
        gradient.locations = [0, 0.52, 1]
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.first?.frame = bounds
    }
}
