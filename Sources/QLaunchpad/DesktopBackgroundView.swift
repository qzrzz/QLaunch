import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin

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
    private struct Candidate {
        let id: CGWindowID
        let score: Double
    }

    static func find(for displayID: CGDirectDisplayID) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let displayBounds = CGDisplayBounds(displayID)
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        var best: Candidate?

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
            let isWindowManagerWallpaper = owner == "windowmanager" &&
                name == "wallpaper" &&
                layer <= desktopLevel + 1

            // Do not fall back to WindowServer/Dock helper windows here. They
            // can be full-screen and opaque-looking, but are not the actual
            // wallpaper surface and often capture as black.
            guard isWindowManagerWallpaper else {
                continue
            }

            let score = 1_000.0

            let candidate = Candidate(id: idNumber.uint32Value, score: score)
            if best == nil || candidate.score > best!.score {
                best = candidate
            }
        }

        return best?.id
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
    ) -> CGImage? {
        guard
            let windowID = WallpaperWindowLocator.find(for: displayID),
            let capturedImage = PrivateWindowServerCapture.capture(windowID: windowID)
        else {
            return nil
        }

        let input = CIImage(cgImage: capturedImage)
        let inputExtent = input.extent
        guard inputExtent.width > 0, inputExtent.height > 0 else { return nil }

        let maximumLongEdge: CGFloat = 2_000
        let scale = min(1, maximumLongEdge / max(inputExtent.width, inputExtent.height))
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = scaled.clampedToExtent()
        blur.radius = Float(max(1, blurRadius * max(scale, 0.5)))

        let controls = CIFilter.colorControls()
        controls.inputImage = blur.outputImage
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
            alpha: 0.18
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
    }

    func prepare(for screen: NSScreen) {
        let screenIdentifier = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID

        if preparedScreenIdentifier != screenIdentifier {
            preparedScreenIdentifier = screenIdentifier
            wallpaperImageView.image = nil
            wallpaperImageView.isHidden = true
            visualEffectView.isHidden = false
        }

        captureGeneration += 1
        let generation = captureGeneration
        captureTask?.cancel()

        let displayID = screenIdentifier ?? CGMainDisplayID()
        let backingScale = screen.backingScaleFactor
        captureTask = Task { [weak self] in
            let image = await self?.renderer.render(
                displayID: displayID,
                backingScale: backingScale,
                blurRadius: 44,
                saturation: 1.22
            )

            guard !Task.isCancelled, let self else { return }
            guard generation == self.captureGeneration else { return }
            guard let image else {
                self.wallpaperImageView.image = nil
                self.wallpaperImageView.isHidden = true
                self.visualEffectView.isHidden = false
                return
            }

            self.wallpaperImageView.image = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
            self.wallpaperImageView.isHidden = false
            self.visualEffectView.isHidden = true
        }
    }

    func prepareForPresentation() {
        wallpaperImageView.alphaValue = 0.72
    }

    func animateWallpaperIn(duration: CFTimeInterval = 0.5) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = wallpaperImageView.layer?.presentation()?.opacity ?? wallpaperImageView.layer?.opacity ?? 1
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wallpaperImageView.layer?.add(animation, forKey: "wallpaperOpacity")
        wallpaperImageView.alphaValue = 1
    }

    func showWallpaperImmediately() {
        wallpaperImageView.layer?.removeAnimation(forKey: "wallpaperOpacity")
        wallpaperImageView.alphaValue = 1
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
            NSColor.black.withAlphaComponent(0.28).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.18).cgColor
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
