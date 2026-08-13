/// Snap math for paging gestures. Mouse-drag on empty space uses a lower
/// commit / flick threshold than trackpad scrolling.
public enum LaunchpadPageSnap {
    /// Trackpad: ~0.85 pages/sec commits the next page.
    public static let trackpadFlickThreshold = 0.85
    /// Trackpad: halfway to the next page.
    public static let trackpadCommitThreshold = 0.5
    /// Mouse empty-area pan: a short swipe is enough.
    public static let mouseFlickThreshold = 0.35
    /// Mouse empty-area pan: about 1/6 of a page instead of half.
    public static let mouseCommitThreshold = 0.16

    public static func settledPage(
        offset: Double,
        origin: Double,
        velocity: Double,
        pageCount: Int,
        flickThreshold: Double,
        commitThreshold: Double
    ) -> Double {
        let minPage = 0.0
        let maxPage = Double(max(pageCount - 1, 0))
        let delta = offset - origin
        let flickedForward = velocity > flickThreshold && delta >= -0.02
        let flickedBack = velocity < -flickThreshold && delta <= 0.02

        let page: Double
        if delta > commitThreshold || flickedForward {
            page = origin + max(1, delta.rounded())
        } else if delta < -commitThreshold || flickedBack {
            page = origin - max(1, (-delta).rounded())
        } else {
            page = origin.rounded()
        }
        return min(max(page, minPage), maxPage)
    }
}
