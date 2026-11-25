import Foundation

/// Separates a two-finger pinch from translation, without claiming the
/// remaining two contacts at the end of a three- or four-finger gesture.
public struct TrackpadCanvasPinch {
    public enum Event: Equatable, Sendable {
        case changed(factor: Double)
        case ended
    }

    private enum Phase { case waiting, pinching, blocked }
    private var phase = Phase.waiting
    private var ids: (Int, Int)?
    private var origin = CGPoint.zero
    private var originDistance = 0.0
    private var lastDistance = 0.0

    public init() {}

    public mutating func update(_ touches: [TrackpadTouch]) -> Event? {
        if touches.isEmpty {
            let wasPinching = phase == .pinching
            self = Self()
            return wasPinching ? .ended : nil
        }
        guard phase != .blocked else { return nil }
        guard touches.count == 2 else {
            return touches.count > 2 || ids != nil ? block() : nil
        }

        let a = touches[0]
        let b = touches[1]
        let center = CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
        let distance = hypot(a.x - b.x, a.y - b.y)
        guard distance.isFinite, center.x.isFinite, center.y.isFinite, a.id != b.id else {
            return block()
        }
        if let ids {
            guard min(a.id, b.id) == ids.0, max(a.id, b.id) == ids.1 else { return block() }
        } else {
            guard distance >= 0.04 else { return nil }
            ids = (min(a.id, b.id), max(a.id, b.id))
            origin = center
            originDistance = distance
            lastDistance = originDistance
            return nil
        }

        if phase == .waiting {
            let spread = abs(distance - originDistance)
            let translation = hypot(center.x - origin.x, center.y - origin.y)
            if translation >= 0.028, translation > spread { return block() }
            guard spread >= 0.012, spread >= translation else { return nil }
            phase = .pinching
        }
        let currentDistance = max(distance, 0.04)
        guard abs(currentDistance - lastDistance) >= 0.0008 else { return nil }
        lastDistance = currentDistance
        return .changed(factor: currentDistance / originDistance)
    }

    private mutating func block() -> Event? {
        let wasPinching = phase == .pinching
        phase = .blocked
        return wasPinching ? .ended : nil
    }
}
