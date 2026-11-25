import CoreGraphics

/// Corners in the launchpad renderer's top-left coordinate system.
public enum LaunchpadPresentationCorner: String, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public func offscreenOrigin(in size: CGSize, margin: CGFloat) -> CGPoint {
        let corner = unitPoint
        return CGPoint(
            x: corner.x == 0 ? -margin : size.width + margin,
            y: corner.y == 0 ? -margin : size.height + margin
        )
    }

    public func staggerPhase(column: CGFloat, row: CGFloat) -> CGFloat {
        let corner = unitPoint
        return (abs(column - corner.x) + abs(row - corner.y)) * 0.5
    }

    private var unitPoint: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .bottomRight: CGPoint(x: 1, y: 1)
        }
    }
}

public enum DirectionalPresentationTransform {
    public static func sample(
        progress: CGFloat,
        staggerPhase: CGFloat,
        initialScale: CGFloat
    ) -> (opacity: CGFloat, scale: CGFloat, position: CGFloat) {
        let stagger: CGFloat = 0.20
        let delay = min(max(staggerPhase, 0), 1) * stagger
        let t = min(max((progress - delay) / (1 - stagger), 0), 1)
        let position = t * t * (3 - 2 * t)
        let fade = min(2 * t, 1)
        let opacity = fade * fade * (3 - 2 * fade)
        return (opacity, initialScale + (1 - initialScale) * position, position)
    }
}
