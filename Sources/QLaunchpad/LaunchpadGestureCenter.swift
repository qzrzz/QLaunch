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
    private var recognizers: [UInt: TrackpadPinchRecognizer] = [:]

    func configure(mode: TrackpadGestureMode) -> Int {
        lock.lock()
        defer { lock.unlock() }
        self.mode = mode
        generation += 1
        recognizers.removeAll()
        return generation
    }

    func receive(device: UInt, touches: [TrackpadTouch], timestamp: Double) {
        lock.lock()
        let triggered = recognizers[device, default: TrackpadPinchRecognizer()].update(touches: touches, timestamp: timestamp, mode: mode)
        let token = generation
        lock.unlock()
        if let triggered {
            DispatchQueue.main.async {
                LaunchpadGestureCenter.shared.trigger(triggered, generation: token)
            }
        }
    }
}

@MainActor
final class LaunchpadGestureCenter: ObservableObject {
    static let shared = LaunchpadGestureCenter()
    @Published private(set) var unavailable = false
    var onTrigger: ((TrackpadPinchDirection) -> Void)?
    private var generation = 0
    private var installed = false
    private var sleeping = false
    private var preferenceObserver: NSObjectProtocol?
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
        generation = TrackpadFrameProcessor.shared.configure(mode: .disabled)
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
    }

    fileprivate func trigger(_ direction: TrackpadPinchDirection, generation: Int) {
        guard installed, self.generation == generation, activeMode != .disabled else { return }
        onTrigger?(direction)
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
