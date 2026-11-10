import Foundation

/// Classic Launchpad gesture: four-finger pinch in opens, spread out closes.
/// Reads raw trackpad contacts from the private MultitouchSupport framework.
final class TrackpadPinchMonitor {
    static let shared = TrackpadPinchMonitor()

    static let enabledKey = "trackpadPinchEnabled"

    var onPinchIn: (() -> Void)?
    var onPinchOut: (() -> Void)?

    /// Mirrors MultitouchSupport's MTTouch (96 bytes).
    private struct MTTouch {
        var frame: Int32
        var timestamp: Double
        var identifier: Int32
        var state: Int32
        var fingerId: Int32
        var handId: Int32
        var x: Float
        var y: Float
        var vx: Float
        var vy: Float
        var total: Float
        var pressure: Float
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var ax: Float
        var ay: Float
        var avx: Float
        var avy: Float
        var field14: Int32
        var field15: Int32
        var density: Float
    }

    private typealias FrameCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Void
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer, FrameCallback) -> Void
    private typealias StartStopFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32

    private let requiredFingers = 4
    private let pinchInRatio = 0.72
    private let pinchOutRatio = 1.35
    private let cooldown: TimeInterval = 0.6

    // Touched only on the MultitouchSupport callback thread.
    private var baselineSpread: Double?
    private var trackedIDs: Set<Int32> = []
    private var firedThisContact = false
    private var lastFireTime: TimeInterval = 0

    private var devices: [UnsafeMutableRawPointer] = []
    private var deviceList: CFArray?
    private var stopFn: StartStopFn?

    private init() {}

    func install() {
        guard devices.isEmpty,
              UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true,
              MemoryLayout<MTTouch>.stride == 96,
              let handle = dlopen(
                  "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                  RTLD_NOW
              ),
              let createSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop")
        else { return }

        let createList = unsafeBitCast(createSym, to: CreateListFn.self)
        let register = unsafeBitCast(registerSym, to: RegisterFn.self)
        let start = unsafeBitCast(startSym, to: StartStopFn.self)
        stopFn = unsafeBitCast(stopSym, to: StartStopFn.self)

        guard let list = createList()?.takeRetainedValue() else { return }
        deviceList = list
        let callback: FrameCallback = { _, touches, count, timestamp, _ in
            TrackpadPinchMonitor.shared.consume(touches: touches, count: Int(count), time: timestamp)
        }
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, callback)
            _ = start(device, 0)
            devices.append(device)
        }
    }

    func uninstall() {
        if let stopFn {
            for device in devices { _ = stopFn(device, 0) }
        }
        devices.removeAll()
        deviceList = nil
    }

    private func consume(touches: UnsafeMutableRawPointer?, count: Int, time: TimeInterval) {
        var points: [(id: Int32, x: Double, y: Double)] = []
        if let touches, count > 0 {
            let buffer = touches.bindMemory(to: MTTouch.self, capacity: count)
            for i in 0..<count {
                let touch = buffer[i]
                // 3 = make touch, 4 = touching.
                if touch.state == 3 || touch.state == 4 {
                    points.append((touch.identifier, Double(touch.x), Double(touch.y)))
                }
            }
        }

        guard points.count == requiredFingers else {
            baselineSpread = nil
            trackedIDs = []
            if points.isEmpty { firedThisContact = false }
            return
        }

        let ids = Set(points.map(\.id))
        let cx = points.map(\.x).reduce(0, +) / Double(points.count)
        let cy = points.map(\.y).reduce(0, +) / Double(points.count)
        let spread = points
            .map { hypot($0.x - cx, $0.y - cy) }
            .reduce(0, +) / Double(points.count)

        guard let baseline = baselineSpread, ids == trackedIDs else {
            baselineSpread = spread
            trackedIDs = ids
            return
        }
        guard !firedThisContact, baseline > 0.05, time - lastFireTime > cooldown else { return }

        let ratio = spread / baseline
        if ratio < pinchInRatio {
            fire(onPinchIn, time: time)
        } else if ratio > pinchOutRatio {
            fire(onPinchOut, time: time)
        }
    }

    private func fire(_ action: (() -> Void)?, time: TimeInterval) {
        firedThisContact = true
        lastFireTime = time
        DispatchQueue.main.async { action?() }
    }
}
