import CoreGraphics

/// An insertion boundary is armed after the dragged icon rests near an icon edge.
public struct LaunchpadInsertionHover {
    public static let dwellDuration: Double = 0.1
    public static let movementDuration: Double = 0.34

    private var candidate: (boundary: Int, point: CGPoint, since: Double)?
    public private(set) var activeBoundary: Int?
    private var activationPoint: CGPoint?

    public init() {}

    public mutating func reset() {
        candidate = nil
        activeBoundary = nil
        activationPoint = nil
    }

    public mutating func update(boundary: Int, point: CGPoint, now: Double) -> Int? {
        if activeBoundary == boundary { return boundary }
        activeBoundary = nil
        activationPoint = nil
        if let candidate, candidate.boundary == boundary,
           hypot(point.x - candidate.point.x, point.y - candidate.point.y) <= 7 {
            if now - candidate.since >= Self.dwellDuration {
                activeBoundary = boundary
                activationPoint = point
            }
        } else {
            candidate = (boundary, point, now)
        }
        return activeBoundary
    }

    /// Keep the preview in its open slot and around the point that opened it.
    /// Only the initial point is stored so the lock cannot follow the drag.
    public func retainedBoundary(at point: CGPoint, openSlotCenter: CGPoint, cellSize: CGSize) -> Int? {
        guard let activeBoundary, let activationPoint,
              cellSize.width > 0, cellSize.height > 0 else { return nil }
        let overOpenSlot = abs(point.x - openSlotCenter.x) <= cellSize.width * 0.45
            && abs(point.y - openSlotCenter.y) <= cellSize.height * 0.45
        let nearActivation = abs(point.x - activationPoint.x) <= cellSize.width * 0.20
            && abs(point.y - activationPoint.y) <= cellSize.height * 0.20
        return overOpenSlot || nearActivation ? activeBoundary : nil
    }

    /// Test against the committed grid so icons moving aside cannot change
    /// the insertion target. Canvas rows can have different leading edges.
    public static func boundary(
        at point: CGPoint,
        firstRowY: CGFloat,
        cellSize: CGSize,
        iconWidth: CGFloat,
        columns: Int,
        itemCount: Int,
        retaining activeBoundary: Int? = nil,
        leadingX: (Int) -> CGFloat
    ) -> Int? {
        guard itemCount > 0, columns > 0, iconWidth > 0,
              cellSize.width > 0, cellSize.height > 0 else { return nil }
        let lastRow = (itemCount - 1) / columns
        let rowPosition = (point.y - firstRowY) / cellSize.height
        let row = Int(min(max(rowPosition.rounded(), 0), CGFloat(lastRow)))
        let rowStart = row * columns
        let rowCount = min(columns, itemCount - rowStart)
        let columnPosition = (point.x - leadingX(rowStart)) / cellSize.width
        let column = Int(min(max(columnPosition.rounded(), 0), CGFloat(rowCount - 1)))

        func target(near index: Int, retaining previous: Int? = nil) -> Int? {
            let rowStart = index / columns * columns
            let dx = point.x - (leadingX(rowStart) + CGFloat(index % columns) * cellSize.width)
            let dy = point.y - (firstRowY + CGFloat(index / columns) * cellSize.height)
            let slop: CGFloat = previous == nil ? 0 : min(6, min(cellSize.width, cellSize.height) * 0.06)
            guard abs(dx) <= cellSize.width * 0.58 + slop,
                  abs(dy) <= cellSize.height * 0.58 + slop else { return nil }

            let xDistance = abs(dx) + slop
            let yDistance = abs(dy) + slop
            let overlap = max(0, iconWidth - xDistance) * max(0, iconWidth - yDistance)
            // In a tight grid, an icon at the midpoint can still overlap both
            // neighbors. Crossing the near edge of a cell also signals insertion.
            let nearHorizontalEdge = xDistance >= iconWidth * 0.5 && xDistance / cellSize.width >= 0.28
            let nearVerticalEdge = yDistance >= iconWidth * 0.5 && yDistance / cellSize.height >= 0.28
            guard overlap <= iconWidth * iconWidth * 0.30 || nearHorizontalEdge || nearVerticalEdge else {
                return nil
            }

            let xWeight = abs(dx) / cellSize.width
            let yWeight = abs(dy) / cellSize.height
            let horizontal = index + (dx < 0 ? 0 : 1)
            let vertical = index + (dy < 0 ? 0 : 1)
            if let previous, abs(xWeight - yWeight) <= slop / min(cellSize.width, cellSize.height),
               previous == horizontal || previous == vertical {
                return previous
            }
            return xWeight >= yWeight ? horizontal : vertical
        }

        let nearest = target(near: rowStart + column)
        if let activeBoundary, nearest != activeBoundary {
            for index in [activeBoundary - 1, activeBoundary] where (0..<itemCount).contains(index) {
                if target(near: index, retaining: activeBoundary) == activeBoundary {
                    return activeBoundary
                }
            }
        }
        return nearest
    }

    public static func movementProgress(_ progress: Double) -> CGFloat {
        let t = CGFloat(min(max(progress, 0), 1))
        return t * t * (3 - 2 * t)
    }
}
