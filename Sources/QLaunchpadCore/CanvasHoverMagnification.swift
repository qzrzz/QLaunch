import CoreGraphics

/// Local magnification that moves nearby icon centers away from the pointer.
public struct CanvasHoverMagnification {
    public let anchor: CGPoint
    public let strength: CGFloat

    public init(anchor: CGPoint, strength: CGFloat) {
        self.anchor = anchor
        self.strength = min(max(strength, 0), 1)
    }

    public func transform(
        center: CGPoint, scale: CGFloat, cellWidth: CGFloat, cellHeight: CGFloat
    ) -> (center: CGPoint, scale: CGFloat) {
        let dx = center.x - anchor.x
        let dy = center.y - anchor.y
        let radiusInCells: CGFloat = 1.7
        let x = dx / max(cellWidth * scale * radiusInCells, 1)
        let y = dy / max(cellHeight * scale * radiusInCells, 1)
        let falloff = max(0, 1 - x * x - y * y)
        let influence = strength * falloff * falloff
        let displacement = 0.22 * influence
        return (
            CGPoint(x: center.x + dx * displacement, y: center.y + dy * displacement),
            scale * (1 + 0.18 * influence)
        )
    }
}
