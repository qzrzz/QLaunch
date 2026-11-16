import AppKit
import Combine
import CMultitouch
import IOKit
import QLaunchpadCore

enum TrackpadGesturePreferences {
    static let modeKey = "launchpadTrackpadGestureMode"
    static let defaultMode = TrackpadGestureMode.disabled

    static var mode: TrackpadGestureMode {
        UserDefaults.standard.string(forKey: modeKey).flatMap(TrackpadGestureMode.init(rawValue:)) ?? defaultMode
    }
}

extension TrackpadGestureMode {
    var title: String { L10n.tr("settings.trackpad." + rawValue) }
}

/// Accessed synchronously from the Multitouch callback; never touches AppKit there.
private final class TrackpadFrameProcessor: @unchecked Sendable {
    static let shared = TrackpadFrameProcessor()
    private let lock = NSLock()
    private var mode = TrackpadGestureMode.disabled
    private var generation = 0
    private var sequences: [UInt: TrackpadPinchRecognizer] = [:]
    private var devicesWithFiveContacts: Set<UInt> = []

    func configure(mode: TrackpadGestureMode) -> Int {
        lock.lock()
        defer { lock.unlock() }
        self.mode = mode
        generation += 1
        sequences.removeAll()
        devicesWithFiveContacts.removeAll()
        return generation
    }

    var hasFiveContacts: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !devicesWithFiveContacts.isEmpty
    }

    func receive(device: UInt, touches: [TrackpadTouch], timestamp: Double) {
        lock.lock()
        if touches.count == 5 {
            devicesWithFiveContacts.insert(device)
        } else {
            devicesWithFiveContacts.remove(device)
        }
        let events = sequences[device, default: TrackpadPinchRecognizer()].update(
            touches: touches, timestamp: timestamp, mode: mode
        )
        let token = generation
        lock.unlock()
        if !events.isEmpty {
            DispatchQueue.main.async {
                for event in events {
                    LaunchpadGestureCenter.shared.receive(event, device: device, generation: token)
                }
            }
        }
    }
}

@MainActor
final class LaunchpadGestureCenter: ObservableObject {
    static let shared = LaunchpadGestureCenter()
    @Published private(set) var unavailable = false
    @Published private(set) var canInterceptSystemSpread = false
    var onProgress: ((TrackpadPinchDirection, CGFloat) -> Bool)?
    var onRelease: ((TrackpadPinchDirection, Bool) -> Void)?
    var visibleLaunchpadGeneration: (() -> UInt?)?
    var launchpadGeneration: (() -> UInt?)?

    private struct GestureStart {
        let desktopWasActive: Bool?
        let launchpadGeneration: UInt?
    }
    private var gestureStarts: [UInt: GestureStart] = [:]
    private var activeGesture: (device: UInt, direction: TrackpadPinchDirection)?
    private var desktopRestoreTask: Task<Void, Never>?
    private var dockPinchTap: CFMachPort?
    private var dockPinchSource: CFRunLoopSource?
    private var isInterceptingDockPinch = false
    private var interceptedDockPinchSinceTouchDown = false

    private var generation = 0
    private var installed = false
    private var sleeping = false
    private var preferenceObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var reloadWork: DispatchWorkItem?

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadIfModeChanged() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification].map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sleeping = false
                    self?.scheduleReload()
                }
            }
        }
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sleeping = true
                self?.reloadWork?.cancel()
                self?.stop()
            }
        })
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.installDockPinchTapIfNeeded() }
        }
        observeDevices()
        reload()
    }

    func uninstall() {
        installed = false
        reloadWork?.cancel()
        reloadWork = nil
        stop()
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        preferenceObserver = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil
    }

    private var activeMode: TrackpadGestureMode?

    private func reloadIfModeChanged() {
        if installed && activeMode != TrackpadGesturePreferences.mode { reload() }
    }

    private func stop() {
        QLMultitouchStop()
        removeDockPinchTap()
        desktopRestoreTask?.cancel()
        desktopRestoreTask = nil
        generation = TrackpadFrameProcessor.shared.configure(mode: .disabled)
        gestureStarts.removeAll()
        let direction = activeGesture?.direction
        activeGesture = nil
        if let direction { onRelease?(direction, false) }
    }

    private func reload() {
        guard installed, !sleeping else { return }
        stop()
        let mode = TrackpadGesturePreferences.mode
        activeMode = mode
        unavailable = false
        guard mode != .disabled else { return }
        generation = TrackpadFrameProcessor.shared.configure(mode: mode)
        let count = QLMultitouchStart { device, contacts, count, timestamp in
            guard let contacts else { return }
            let touches = UnsafeBufferPointer(start: contacts, count: Int(count)).map {
                TrackpadTouch(id: Int($0.identifier), x: Double($0.x), y: Double($0.y))
            }
            TrackpadFrameProcessor.shared.receive(device: device, touches: touches, timestamp: timestamp)
        }
        unavailable = count <= 0
        installDockPinchTapIfNeeded()
    }

    fileprivate func receive(_ event: TrackpadPinchRecognizer.Event, device: UInt, generation: Int) {
        guard installed, self.generation == generation, activeMode != .disabled else { return }
        switch event {
        case .began:
            desktopRestoreTask?.cancel()
            desktopRestoreTask = nil
            if gestureStarts.isEmpty {
                interceptedDockPinchSinceTouchDown = isInterceptingDockPinch
            }
            let visibleGeneration = visibleLaunchpadGeneration?()
            gestureStarts[device] = GestureStart(
                desktopWasActive: visibleGeneration != nil && activeMode == .three
                    ? nil : SystemDesktopReveal.isActive(),
                launchpadGeneration: visibleGeneration
            )
        case .changed(let motion):
            guard let start = gestureStarts[device] else { return }
            if let activeGesture {
                guard activeGesture.device == device else { return }
            } else {
                switch motion.direction {
                case .inward:
                    guard start.launchpadGeneration == nil, start.desktopWasActive != true,
                          SystemDesktopReveal.isActive() != true else {
                        gestureStarts.removeValue(forKey: device)
                        return
                    }
                case .outward:
                    guard let launchpadGeneration = start.launchpadGeneration,
                          visibleLaunchpadGeneration?() == launchpadGeneration else { return }
                }
            }
            if onProgress?(motion.direction, CGFloat(motion.progress)) == true {
                activeGesture = (device, motion.direction)
            }
        case .ended(let motion):
            endGesture(on: device, shouldComplete: motion?.shouldComplete == true)
        case .cancelled:
            endGesture(on: device, shouldComplete: false)
        }
    }

    private func endGesture(on device: UInt, shouldComplete: Bool) {
        let start = gestureStarts.removeValue(forKey: device)
        guard let activeGesture, activeGesture.device == device else { return }
        self.activeGesture = nil
        onRelease?(activeGesture.direction, shouldComplete)
        if activeGesture.direction == .outward, activeMode != .three,
           start?.desktopWasActive == false, let presentation = start?.launchpadGeneration,
           !interceptedDockPinchSinceTouchDown {
            restoreDesktopAfterSpread(in: presentation)
        }
    }

    private func restoreDesktopAfterSpread(in presentation: UInt) {
        // Some systems don't expose a writable event tap. If the system acted
        // on this stroke, restore its previous state outside the animation clock.
        desktopRestoreTask?.cancel()
        desktopRestoreTask = Task { [weak self] in
            for delay in [130, 150] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self,
                      self.launchpadGeneration?() == presentation,
                      !self.interceptedDockPinchSinceTouchDown else { return }
                SystemDesktopReveal.restoreWindowsIfDesktopIsActive()
            }
        }
    }

    private func installDockPinchTapIfNeeded() {
        guard installed, !sleeping, !unavailable,
              activeMode == .fourOrFive || activeMode == .five,
              dockPinchTap == nil else { return }

        // CGEvent type 30 is DockControl. Subscribe only to this stream.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: 1 << 30,
            callback: { _, type, event, _ in
                MainActor.assumeIsolated { LaunchpadGestureCenter.shared.filterDockPinch(type, event) }
            }, userInfo: nil
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
        dockPinchTap = tap
        dockPinchSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        canInterceptSystemSpread = true
    }

    private func removeDockPinchTap() {
        if let source = dockPinchSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = dockPinchTap { CFMachPortInvalidate(tap) }
        dockPinchTap = nil
        dockPinchSource = nil
        isInterceptingDockPinch = false
        interceptedDockPinchSinceTouchDown = false
        if canInterceptSystemSpread { canInterceptSystemSpread = false }
    }

    private func filterDockPinch(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            isInterceptingDockPinch = false
            interceptedDockPinchSinceTouchDown = false
            if let tap = dockPinchTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                canInterceptSystemSpread = CGEvent.tapIsEnabled(tap: tap)
            }
            return .passUnretained(event)
        }

        // DockSwipe (field 110) with the pinch axis (field 123).
        // Horizontal Spaces and vertical Mission Control swipes pass through.
        guard type.rawValue == 30,
              event.getIntegerValueField(CGEventField(rawValue: 110)!) == 23,
              event.getIntegerValueField(CGEventField(rawValue: 123)!) == 3 else {
            return .passUnretained(event)
        }
        // Hold ownership through the final phase even if the panel has closed.
        let phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
        if phase == 1 {
            isInterceptingDockPinch = (activeGesture?.direction == .outward || visibleLaunchpadGeneration?() != nil)
                && (activeMode != .five || TrackpadFrameProcessor.shared.hasFiveContacts)
            if isInterceptingDockPinch { interceptedDockPinchSinceTouchDown = true }
        }
        guard isInterceptingDockPinch else { return .passUnretained(event) }
        if phase == 4 || phase == 8 { isInterceptingDockPinch = false }
        return nil
    }

    fileprivate func scheduleReload() {
        guard installed, !sleeping else { return }
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        // Coalesce device attach/remove notifications; no periodic polling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func observeDevices() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let callback: IOServiceMatchingCallback = { _, iterator in
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            Task { @MainActor in LaunchpadGestureCenter.shared.scheduleReload() }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"), callback, nil, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("AppleMultitouchDevice"), callback, nil, &removedIterator)
        // Drain the initial contents to arm notifications without scheduling a reload.
        for iterator in [addedIterator, removedIterator] where iterator != 0 {
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
        }
    }
}
