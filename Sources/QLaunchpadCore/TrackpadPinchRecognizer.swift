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

public enum TrackpadPinchDirection: Sendable {
    case inward
    case outward
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
    private var direction: TrackpadPinchDirection?

    public init() {}

    public mutating func update(touches: [TrackpadTouch], timestamp: Double, mode: TrackpadGestureMode) -> TrackpadPinchDirection? {
        guard timestamp.isFinite else { return nil }
        // Recover from a lost lift-off frame or a device timestamp reset.
        if let lastTimestamp, timestamp < lastTimestamp || timestamp - lastTimestamp > 0.25 {
            self = Self()
        }
        lastTimestamp = timestamp
        if touches.isEmpty {
            self = Self()
            return nil
        }
        guard !blockedUntilLift, mode != .disabled else { return nil }
        guard touches.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              Set(touches.map(\.id)).count == touches.count else {
            blockedUntilLift = true
            return nil
        }
        if touches.count > mode.maximumCount {
            blockedUntilLift = true
            return nil
        }
        guard mode.accepts(touches.count) else {
            identifiers = []
            direction = nil
            return nil
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
            direction = nil
            return nil
        }
        let elapsed = timestamp - beganAt
        guard elapsed <= 1.5 else {
            blockedUntilLift = true
            return nil
        }
        // Commit to the first meaningful direction, so a spread cannot rebound
        // into an opening pinch (or vice versa) within the same contact sequence.
        if direction == nil {
            if radius <= initialRadius * 0.85 { direction = .inward }
            else if radius >= initialRadius * 1.15 { direction = .outward }
        }
        guard elapsed >= 0.12, initialRadius >= 0.08,
              hypot(x - initialX, y - initialY) <= initialRadius * 0.8 else { return nil }
        let recognized: TrackpadPinchDirection
        if direction == .inward, radius <= initialRadius * 0.72, initialRadius - radius >= 0.055 {
            recognized = .inward
        } else if direction == .outward, radius >= initialRadius / 0.72, radius - initialRadius >= 0.055 {
            recognized = .outward
        } else {
            return nil
        }
        blockedUntilLift = true
        return recognized
    }
}
