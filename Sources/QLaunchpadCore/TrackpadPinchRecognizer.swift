import Foundation

public enum TrackpadGestureMode: String, CaseIterable, Identifiable, Sendable {
    case disabled
    case fourOrFive
    case three
    case five

    public var id: String { rawValue }

    public func accepts(_ count: Int) -> Bool {
        switch self {
        case .disabled: false
        case .fourOrFive: count == 4 || count == 5
        case .three: count == 3
        case .five: count == 5
        }
    }

    fileprivate var maximumCount: Int { self == .three ? 3 : 5 }
}

public struct TrackpadTouch: Sendable {
    public var id: Int
    public var x: Double
    public var y: Double

    public init(id: Int, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// One recognizer per physical device. Coordinates use the normalized trackpad surface.
public struct TrackpadPinchRecognizer {
    private var identifiers: [Int] = []
    private var initialRadius = 0.0
    private var initialX = 0.0
    private var initialY = 0.0
    private var beganAt = 0.0
    private var lastTimestamp: Double?
    private var blockedUntilLift = false

    public init() {}

    public mutating func update(touches: [TrackpadTouch], timestamp: Double, mode: TrackpadGestureMode) -> Bool {
        guard timestamp.isFinite else { return false }
        // Recover from a lost lift-off frame or a device timestamp reset.
        if let lastTimestamp, timestamp < lastTimestamp || timestamp - lastTimestamp > 0.25 {
            self = Self()
        }
        lastTimestamp = timestamp
        if touches.isEmpty {
            self = Self()
            return false
        }
        guard !blockedUntilLift, mode != .disabled else { return false }
        guard touches.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              Set(touches.map(\.id)).count == touches.count else {
            blockedUntilLift = true
            return false
        }
        if touches.count > mode.maximumCount {
            blockedUntilLift = true
            return false
        }
        guard mode.accepts(touches.count) else {
            identifiers = []
            return false
        }
        let ids = touches.map(\.id).sorted()
        let x = touches.map(\.x).reduce(0, +) / Double(touches.count)
        let y = touches.map(\.y).reduce(0, +) / Double(touches.count)
        let radius = touches.reduce(0.0) { $0 + hypot($1.x - x, $1.y - y) } / Double(touches.count)
        if identifiers != ids {
            identifiers = ids
            initialRadius = radius
            initialX = x
            initialY = y
            beganAt = timestamp
            return false
        }
        let elapsed = timestamp - beganAt
        // An outward gesture belongs to Show Desktop; do not recognize its rebound.
        guard elapsed <= 1.5, radius <= initialRadius * 1.15 else {
            blockedUntilLift = true
            return false
        }
        guard elapsed >= 0.12, initialRadius >= 0.08,
              radius <= initialRadius * 0.72, initialRadius - radius >= 0.055,
              hypot(x - initialX, y - initialY) <= initialRadius * 0.8 else { return false }
        blockedUntilLift = true
        return true
    }
}
