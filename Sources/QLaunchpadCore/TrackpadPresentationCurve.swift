import Foundation

public enum TrackpadPresentationCurve {
    /// A gentle start followed by progressively stronger blur, normalized
    /// so the last gesture frame matches the configured blur exactly.
    public static func blurProgress(_ progress: CGFloat) -> CGFloat {
        let phase = min(1, max(0, progress))
        let exponent: CGFloat = 1.4
        return expm1(exponent * phase) / expm1(exponent)
    }

    /// Follow small touch changes with low latency and limit how much of
    /// the flight can pass in one frame when a large touch change arrives.
    public static func nextInwardProgress(
        from current: CGFloat, toward target: CGFloat, elapsed: TimeInterval
    ) -> CGFloat {
        let frameTime = CGFloat(min(max(elapsed, 0), 1.0 / 30.0))
        let remaining = target - current
        let response = -expm1(-frameTime / 0.028)
        let maximumStep = 2.75 * frameTime
        if abs(remaining) <= min(0.0005, maximumStep) { return target }
        let step = min(maximumStep, max(-maximumStep, remaining * response))
        return current + step
    }
}
