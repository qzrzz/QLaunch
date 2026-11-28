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

public enum TrackpadPinchDirection: Equatable, Sendable {
    case inward
    case outward
}

public struct TrackpadPinchMotion: Equatable, Sendable {
    public let direction: TrackpadPinchDirection
    public let progress: Double
    public let shouldComplete: Bool
}

/// Reports motion and lift separately. A pause or a partial lift preserves the
/// last visual progress until the remaining contacts leave the trackpad.
public struct TrackpadPinchRecognizer {
    public enum Event: Equatable, Sendable {
        case began
        case changed(TrackpadPinchMotion)
        case ended(TrackpadPinchMotion?)
        case cancelled
    }

    private var identifiers: Set<Int> = []
    private var baselineCenter = (x: 0.0, y: 0.0)
    private var baselineRadius = 0.0
    private var lastTimestamp: Double?
    private var isTracking = false
    private var blockedUntilLift = false
    private var motion: TrackpadPinchMotion?
    private var trackedTravel = 0.0

    public init() {}

    public mutating func update(
        touches: [TrackpadTouch], timestamp: Double, mode: TrackpadGestureMode
    ) -> [Event] {
        guard timestamp.isFinite, mode != .disabled else { return [] }
        if touches.isEmpty {
            let events: [Event] = isTracking ? [.ended(motion)] : []
            self = Self()
            return events
        }

        var events: [Event] = []
        let ids = Set(touches.map(\.id))
        if let lastTimestamp,
           timestamp < lastTimestamp
           || (timestamp - lastTimestamp > 0.25 && ids.isDisjoint(with: identifiers)) {
            if isTracking { events.append(.cancelled) }
            self = Self()
        }
        lastTimestamp = timestamp

        if !isTracking, touches.count >= 3 {
            isTracking = true
            events.append(.began)
        }
        guard !blockedUntilLift else { return events }
        guard touches.count <= mode.maximumCount, ids.count == touches.count,
              touches.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            blockedUntilLift = true
            if motion != nil {
                motion = nil
                events.append(.cancelled)
            }
            return events
        }

        if !mode.accepts(touches.count) {
            if motion == nil { identifiers.removeAll() }
            return events
        }
        let center = (
            x: touches.reduce(0) { $0 + $1.x } / Double(touches.count),
            y: touches.reduce(0) { $0 + $1.y } / Double(touches.count)
        )
        let radius = touches.reduce(0) {
            $0 + hypot($1.x - center.x, $1.y - center.y)
        } / Double(touches.count)
        if identifiers != ids {
            // The first matching contact set sets the baseline. If a finger
            // leaves after motion is underway, hold rather than jumping.
            if motion == nil {
                identifiers = ids
                baselineCenter = center
                baselineRadius = radius
            }
            return events
        }
        guard baselineRadius >= 0.08 else { return events }

        let change = radius - baselineRadius
        let slop = max(0.008, baselineRadius * 0.06)
        if motion == nil {
            guard abs(change) > slop,
                  hypot(center.x - baselineCenter.x, center.y - baselineCenter.y)
                    <= baselineRadius * 0.8 else { return events }
        }
        let direction = motion?.direction ?? (change < 0 ? .inward : .outward)
        let travel = max(0, direction == .inward ? -change : change)
        // Keep the visual position through small reversals. Once a reversal
        // leaves the dead band, move at the same rate as the original pinch.
        // Taper the band near the origin so a full reversal can reach zero.
        let reversalSlop = min(travel * 0.75, max(0.015, baselineRadius * 0.075))
        trackedTravel = max(travel, min(trackedTravel, travel + reversalSlop))
        let releaseFraction = direction == .inward ? 0.16 : 0.23
        let previewFraction = direction == .inward ? 0.30 : 0.38
        let threshold = max(0.036, baselineRadius * releaseFraction)
        let previewDistance = max(0.074, baselineRadius * previewFraction)
        let maximumProgress = direction == .outward ? 1.0 : 0.96
        let progress = min(maximumProgress, max(0, (trackedTravel - slop) / (previewDistance - slop)))
        let updated = TrackpadPinchMotion(
            direction: direction, progress: progress, shouldComplete: trackedTravel >= threshold
        )
        let minimumReportedChange = direction == .inward ? 0.0008 : 0.012
        if let motion, progress != 0, progress != maximumProgress,
           motion.shouldComplete == updated.shouldComplete,
           abs(progress - motion.progress) < minimumReportedChange { return events }
        if motion == updated { return events }
        motion = updated
        events.append(.changed(updated))
        return events
    }
}
