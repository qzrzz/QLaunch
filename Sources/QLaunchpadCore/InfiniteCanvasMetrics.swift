import CoreGraphics
import Foundation

/// World-space geometry for the non-paged 16 × N canvas. Its unscaled cell
/// pitch deliberately matches the existing 6 × 4 layout.
public struct InfiniteCanvasMetrics: Equatable, Sendable {
    public static let columns = 16
    public static let panBoundaryPadding: CGFloat = 200

    public let size: CGSize
    public let itemCount: Int
    public let columnCount: Int
    public let rows: Int
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let worldSize: CGSize
    public let viewportCenter: CGPoint
    public let availableSize: CGSize
    public let maximumScale: CGFloat

    private let centersIncompleteLastRow: Bool

    public init(
        size: CGSize,
        itemCount: Int,
        adaptsToItemCount: Bool = false,
        maximumScale: CGFloat = 1
    ) {
        self.size = size
        self.itemCount = max(itemCount, 0)
        self.maximumScale = max(maximumScale, 1)
        centersIncompleteLastRow = adaptsToItemCount

        let iconSize: CGFloat = 128
        let hInset: CGFloat = 80
        let vInsetTop: CGFloat = 120
        let vInsetBottom: CGFloat = 96
        let availableWidth = max(size.width - hInset * 2, 1)
        let availableHeight = max(size.height - vInsetTop - vInsetBottom, 1)
        availableSize = CGSize(width: availableWidth, height: availableHeight)
        viewportCenter = CGPoint(
            x: size.width * 0.5,
            y: vInsetTop + availableHeight * 0.5
        )

        let idealCellWidth = availableWidth / 6
        cellWidth = min(max(idealCellWidth, iconSize + 28), 220)
        let idealCellHeight = availableHeight / 4
        cellHeight = min(max(idealCellHeight, iconSize + 48), 220)
        columnCount = adaptsToItemCount
            ? Self.bestFittingColumnCount(
                itemCount: itemCount,
                availableSize: availableSize,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                maximumScale: self.maximumScale
            )
            : Self.columns
        rows = max(1, Int(ceil(Double(max(itemCount, 1)) / Double(columnCount))))
        worldSize = CGSize(
            width: cellWidth * CGFloat(columnCount),
            height: cellHeight * CGFloat(rows)
        )
    }

    public var fittedScale: CGFloat {
        min(
            maximumScale,
            0.92 * min(
                availableSize.width / max(worldSize.width, 1),
                availableSize.height / max(worldSize.height, 1)
            )
        )
    }

    /// Initial root-canvas scale: cover the usable viewport and extend slightly
    /// beyond one axis. `fittedScale` remains the zoom-out floor for full overview.
    public var viewportFillingScale: CGFloat {
        min(
            maximumScale,
            1.06 * max(
                availableSize.width / max(worldSize.width, 1),
                availableSize.height / max(worldSize.height, 1)
            )
        )
    }

    public func worldCenter(globalIndex: Double) -> CGPoint {
        let lowerIndex = max(0, Int(floor(globalIndex)))
        let upperIndex = max(lowerIndex, Int(ceil(globalIndex)))
        let fraction = CGFloat(globalIndex - floor(globalIndex))
        let lower = worldCenter(index: lowerIndex)
        let upper = worldCenter(index: upperIndex)
        return CGPoint(
            x: lower.x + (upper.x - lower.x) * fraction,
            y: lower.y + (upper.y - lower.y) * fraction
        )
    }

    public func screenCenter(globalIndex: Double, scale: CGFloat, pan: CGPoint) -> CGPoint {
        let world = worldCenter(globalIndex: globalIndex)
        return CGPoint(
            x: viewportCenter.x + pan.x + (world.x - worldSize.width * 0.5) * scale,
            y: viewportCenter.y + pan.y + (world.y - worldSize.height * 0.5) * scale
        )
    }

    public func itemIndex(atTopLeftPoint point: CGPoint, scale: CGFloat, pan: CGPoint) -> Int? {
        guard scale > 0 else { return nil }
        let worldX = (point.x - viewportCenter.x - pan.x) / scale + worldSize.width * 0.5
        let worldY = (point.y - viewportCenter.y - pan.y) / scale + worldSize.height * 0.5
        let column = Int(floor(worldX / cellWidth))
        let row = Int(floor(worldY / cellHeight))
        guard column >= 0, column < columnCount, row >= 0, row < rows else { return nil }
        let rowStart = row * columnCount
        let itemsInRow = min(columnCount, max(itemCount - rowStart, 0))
        let rowOffset = centersIncompleteLastRow
            ? CGFloat(columnCount - itemsInRow) * cellWidth * 0.5
            : 0
        let adjustedColumn = Int(floor((worldX - rowOffset) / cellWidth))
        guard adjustedColumn >= 0, adjustedColumn < itemsInRow else { return nil }
        let index = rowStart + adjustedColumn
        return index < itemCount ? index : nil
    }

    public func clampedPan(_ proposed: CGPoint, scale: CGFloat) -> CGPoint {
        // Let the outer canvas edge travel into the viewport, leaving a useful
        // blank working margin while the last row/column remains visible.
        let limitX = max(0, (worldSize.width * scale - availableSize.width) * 0.5)
            + Self.panBoundaryPadding
        let limitY = max(0, (worldSize.height * scale - availableSize.height) * 0.5)
            + Self.panBoundaryPadding
        return CGPoint(
            x: min(max(proposed.x, -limitX), limitX),
            y: min(max(proposed.y, -limitY), limitY)
        )
    }

    /// Zoom around a finger's screen location, keeping the same world point
    /// beneath it unless a canvas boundary requires clamping.
    public func cameraZoomed(
        scale: CGFloat,
        pan: CGPoint,
        factor: CGFloat,
        anchor: CGPoint,
        minimumScale: CGFloat,
        maximumScale: CGFloat
    ) -> (scale: CGFloat, pan: CGPoint) {
        let newScale = min(max(scale * factor, minimumScale), maximumScale)
        let world = worldPoint(atScreenPoint: anchor, scale: scale, pan: pan)
        return (newScale, clampedPan(
            self.pan(placing: world, atScreenPoint: anchor, scale: newScale),
            scale: newScale
        ))
    }

    /// Keep the same grid location under the previous viewport center after
    /// the world size, cell pitch, or item count changes. Reorder, grouping,
    /// and window resize must not rewrite the user's zoom.
    public func cameraPreservingGridPoint(
        from old: InfiniteCanvasMetrics,
        scale: CGFloat,
        pan: CGPoint,
        minimumScale: CGFloat,
        maximumScale: CGFloat
    ) -> (scale: CGFloat, pan: CGPoint) {
        let oldWorld = old.worldPoint(
            atScreenPoint: old.viewportCenter,
            scale: scale,
            pan: pan
        )
        let grid = old.gridPoint(forWorldPoint: oldWorld)
        let newWorld = worldPoint(forGridPoint: grid)
        let newScale = min(max(scale, minimumScale), maximumScale)
        let newPan = clampedPan(
            self.pan(placing: newWorld, atScreenPoint: viewportCenter, scale: newScale),
            scale: newScale
        )
        return (newScale, newPan)
    }

    func worldPoint(atScreenPoint screen: CGPoint, scale: CGFloat, pan: CGPoint) -> CGPoint {
        let safeScale = max(scale, 0.0001)
        return CGPoint(
            x: (screen.x - viewportCenter.x - pan.x) / safeScale + worldSize.width * 0.5,
            y: (screen.y - viewportCenter.y - pan.y) / safeScale + worldSize.height * 0.5
        )
    }

    func gridPoint(forWorldPoint world: CGPoint) -> CGPoint {
        CGPoint(
            x: world.x / max(cellWidth, 1),
            y: world.y / max(cellHeight, 1)
        )
    }

    func worldPoint(forGridPoint grid: CGPoint) -> CGPoint {
        CGPoint(x: grid.x * cellWidth, y: grid.y * cellHeight)
    }

    func pan(placing worldPoint: CGPoint, atScreenPoint screen: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(
            x: screen.x - viewportCenter.x - (worldPoint.x - worldSize.width * 0.5) * scale,
            y: screen.y - viewportCenter.y - (worldPoint.y - worldSize.height * 0.5) * scale
        )
    }

    private func worldCenter(index: Int) -> CGPoint {
        let row = index / columnCount
        let column = index % columnCount
        let rowStart = row * columnCount
        let itemsInRow = min(columnCount, max(itemCount - rowStart, 0))
        let rowOffset = centersIncompleteLastRow
            ? CGFloat(columnCount - itemsInRow) * cellWidth * 0.5
            : 0
        return CGPoint(
            x: rowOffset + cellWidth * (CGFloat(column) + 0.5),
            y: cellHeight * (CGFloat(row) + 0.5)
        )
    }

    private static func bestFittingColumnCount(
        itemCount: Int,
        availableSize: CGSize,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        maximumScale: CGFloat
    ) -> Int {
        let maximum = min(max(itemCount, 1), columns)
        var bestColumns = 1
        var bestScale: CGFloat = 0
        for candidate in 1...maximum {
            let candidateRows = max(1, Int(ceil(Double(max(itemCount, 1)) / Double(candidate))))
            let scale = min(
                maximumScale,
                0.92 * min(
                    availableSize.width / max(cellWidth * CGFloat(candidate), 1),
                    availableSize.height / max(cellHeight * CGFloat(candidateRows), 1)
                )
            )
            if scale > bestScale + 0.0001
                || (abs(scale - bestScale) <= 0.0001 && candidate > bestColumns) {
                bestScale = scale
                bestColumns = candidate
            }
        }
        return bestColumns
    }
}
