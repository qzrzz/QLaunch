import CoreGraphics

public enum ClassicPresentationTransform {
    public static let expandedScale: CGFloat = 1.12

    public static func scale(
        progress: CGFloat,
        showing: Bool,
        expandedScale: CGFloat = expandedScale
    ) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        let distance = max(expandedScale - 1, 0)
        if showing {
            let remaining = 1 - progress
            return 1 + distance * remaining * remaining * remaining
        }
        return 1 + distance * (1 - progress * progress * progress)
    }
}
