import AppKit
import Combine
import Foundation

public enum HotCornerPosition: String, CaseIterable, Identifiable {
    case none
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: L10n.tr("settings.hotCorner.none")
        case .topLeft: L10n.tr("settings.hotCorner.topLeft")
        case .topRight: L10n.tr("settings.hotCorner.topRight")
        case .bottomLeft: L10n.tr("settings.hotCorner.bottomLeft")
        case .bottomRight: L10n.tr("settings.hotCorner.bottomRight")
        }
    }
}

public enum HotCornerPreferences {
    public static let positionKey = "launchpadHotCornerPosition"
    public static let defaultPosition: HotCornerPosition = .none

    public static var position: HotCornerPosition {
        get {
            guard let raw = UserDefaults.standard.string(forKey: positionKey),
                  let pos = HotCornerPosition(rawValue: raw) else {
                return defaultPosition
            }
            return pos
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: positionKey)
        }
    }
}

extension Notification.Name {
    static let qlaunchpadHotCornerChanged = Notification.Name("QLaunchpadHotCornerChanged")
}

private final class HotCornerTrackingView: NSView {
    var onTrigger: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private var dwellTimer: Timer?
    private var hasTriggered = false
    private let dwellDuration: TimeInterval = 0.2

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !hasTriggered else { return }

        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: dwellDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.hasTriggered else { return }
                self.hasTriggered = true
                self.onTrigger?()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        dwellTimer?.invalidate()
        dwellTimer = nil
        hasTriggered = false
    }
}

private final class HotCornerWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect, onTrigger: @escaping () -> Void) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let trackingView = HotCornerTrackingView(frame: NSRect(origin: .zero, size: frame.size))
        trackingView.onTrigger = onTrigger
        contentView = trackingView
    }
}

@MainActor
final class LaunchpadHotCornerCenter: ObservableObject {
    static let shared = LaunchpadHotCornerCenter()

    var onTrigger: (() -> Void)?
    private var cornerWindows: [HotCornerWindow] = []
    private var screenObserver: NSObjectProtocol?
    private let cornerSize: CGFloat = 4.0

    private init() {}

    func install() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadWindows()
            }
        }
        reloadWindows()
    }

    func uninstall() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        tearDownWindows()
    }

    func reloadWindows() {
        tearDownWindows()

        let position = HotCornerPreferences.position
        guard position != .none else { return }

        for screen in NSScreen.screens {
            guard let windowFrame = frame(for: position, on: screen) else { continue }
            let window = HotCornerWindow(frame: windowFrame) { [weak self] in
                self?.onTrigger?()
            }
            window.orderFrontRegardless()
            cornerWindows.append(window)
        }
    }

    private func tearDownWindows() {
        for window in cornerWindows {
            window.orderOut(nil)
        }
        cornerWindows.removeAll()
    }

    private func frame(for corner: HotCornerPosition, on screen: NSScreen) -> NSRect? {
        let bounds = screen.frame
        switch corner {
        case .none:
            return nil
        case .topLeft:
            return NSRect(
                x: bounds.minX,
                y: bounds.maxY - cornerSize,
                width: cornerSize,
                height: cornerSize
            )
        case .topRight:
            return NSRect(
                x: bounds.maxX - cornerSize,
                y: bounds.maxY - cornerSize,
                width: cornerSize,
                height: cornerSize
            )
        case .bottomLeft:
            return NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: cornerSize,
                height: cornerSize
            )
        case .bottomRight:
            return NSRect(
                x: bounds.maxX - cornerSize,
                y: bounds.minY,
                width: cornerSize,
                height: cornerSize
            )
        }
    }
}
