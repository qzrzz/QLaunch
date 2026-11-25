/// Time-based page motion with a continuous arrival and optional swipe velocity.
public struct LaunchpadPageTransition {
    public let destination: Double
    public let duration: Double
    private let origin: Double
    private let start: Double
    private let initialSlope: Double

    public init(from origin: Double, to destination: Double, start: Double,
                incomingVelocity: Double? = nil) {
        self.origin = origin
        self.destination = destination
        self.start = start
        let distance = destination - origin
        if let incomingVelocity, distance != 0 {
            duration = 0.18 + 0.14 * min(abs(distance), 1)
            // Express the incoming velocity as a slope of the unit curve.
            // Keeping it in 0...2 lets the grid settle without overshoot.
            initialSlope = min(max(incomingVelocity * duration / distance, 0), 2)
        } else {
            duration = 0.32
            initialSlope = 0
        }
    }

    public func position(at time: Double) -> Double {
        let t = (time - start) / duration
        if t <= 0 { return origin }
        if t >= 1 { return destination }
        let remaining = 1 - t
        let progress = t * t * (3 - 2 * t) + initialSlope * t * remaining * remaining
        return origin + (destination - origin) * progress
    }
}
