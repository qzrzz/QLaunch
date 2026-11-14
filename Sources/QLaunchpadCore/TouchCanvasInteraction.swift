/// Tracks the lifetime of overlapping canvas pan and pinch gestures. Ending
/// either recognizer must not restore pointer interaction while the other runs.
public struct TouchCanvasInteraction {
    public enum Gesture: Hashable {
        case pan
        case magnification
    }

    private var activeGestures: Set<Gesture> = []

    public init() {}

    public var isActive: Bool { !activeGestures.isEmpty }

    /// Returns true only when the first canvas recognizer takes ownership.
    @discardableResult
    public mutating func begin(_ gesture: Gesture) -> Bool {
        let wasActive = isActive
        activeGestures.insert(gesture)
        return !wasActive
    }

    public mutating func end(_ gesture: Gesture) {
        activeGestures.remove(gesture)
    }

    public mutating func reset() {
        activeGestures.removeAll()
    }
}
