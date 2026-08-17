import CoreGraphics
import Foundation
import QLaunchpadCore

/// Layout metrics for a Launchpad-style icon grid.
/// Icon texture pixel size normally follows the selected render quality. Compact
/// 64pt layouts always bake at 128px so their textures stay at the intended 2× size.
enum GridLayoutPreset: String, CaseIterable, Identifiable {
    case fourByTwo = "4x2-256"
    case fiveByFour = "5x4-128"
    case sixByFour = "6x4-128"
    case sevenByFive = "7x5-128"
    case infiniteCanvas = "infinite-canvas-128"
    case infiniteCanvas256 = "infinite-canvas-256"
    case sevenByFiveCompact = "7x5-64"
    case eightBySevenCompact = "8x7-64"

    static let defaultsKey = LaunchpadPersistence.gridLayoutPresetKey
    static let defaultPreset: Self = .sixByFour
    static let menuGroups: [[Self]] = [
        [.fourByTwo, .infiniteCanvas256],
        [.fiveByFour, .sixByFour, .sevenByFive, .infiniteCanvas],
        [.sevenByFiveCompact, .eightBySevenCompact],
    ]

    var id: Self { self }

    var columns: Int {
        switch self {
        case .fourByTwo: 4
        case .fiveByFour: 5
        case .sixByFour: 6
        case .sevenByFive, .sevenByFiveCompact: 7
        case .eightBySevenCompact: 8
        case .infiniteCanvas, .infiniteCanvas256: 16
        }
    }

    var rows: Int {
        switch self {
        case .fourByTwo: 2
        case .fiveByFour, .sixByFour: 4
        case .sevenByFive, .sevenByFiveCompact: 5
        case .eightBySevenCompact: 7
        case .infiniteCanvas, .infiniteCanvas256: 1
        }
    }

    var title: String {
        switch self {
        case .fourByTwo: "4 × 2 (256pt)"
        case .fiveByFour: "5 × 4 (128pt)"
        case .sixByFour: "6 × 4 (128pt)"
        case .sevenByFive: "7 × 5 (128pt)"
        case .infiniteCanvas: L10n.tr("grid.infiniteCanvas.128")
        case .infiniteCanvas256: L10n.tr("grid.infiniteCanvas.256")
        case .sevenByFiveCompact: "7 × 5 (64pt)"
        case .eightBySevenCompact: "8 × 7 (64pt)"
        }
    }

    static var current: Self {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
              let preset = Self(rawValue: rawValue) else {
            return defaultPreset
        }
        return preset
    }

    var iconPointSize: CGFloat {
        switch self {
        case .fourByTwo, .infiniteCanvas256: 256
        case .fiveByFour, .sixByFour, .sevenByFive, .infiniteCanvas: 128
        case .sevenByFiveCompact, .eightBySevenCompact: 64
        }
    }

    /// Compact layouts tighten the clear space between neighboring icons.
    var spacingScale: CGFloat {
        switch self {
        case .sevenByFiveCompact: 0.6
        case .eightBySevenCompact: 0.7
        case .fourByTwo, .fiveByFour, .sixByFour, .sevenByFive,
             .infiniteCanvas, .infiniteCanvas256: 1
        }
    }

    /// Texture edge length used to rasterize icons for this layout.
    func iconPixelSize(for quality: IconRenderQuality) -> Int {
        switch self {
        case .sevenByFiveCompact, .eightBySevenCompact:
            128
        case .fourByTwo, .fiveByFour, .sixByFour, .sevenByFive,
             .infiniteCanvas, .infiniteCanvas256:
            Int(iconPointSize * quality.rasterScale)
        }
    }

    var isInfiniteCanvas: Bool {
        switch self {
        case .infiniteCanvas, .infiniteCanvas256: true
        case .fourByTwo, .fiveByFour, .sixByFour, .sevenByFive,
             .sevenByFiveCompact, .eightBySevenCompact: false
        }
    }

    /// Row count written to layout snapshots. Paged grids use their fixed
    /// geometry; an infinite canvas grows vertically to contain every root item.
    func exportedRows(itemCount: Int) -> Int {
        guard isInfiniteCanvas else { return rows }
        return max(
            1,
            Int(ceil(Double(max(itemCount, 1)) / Double(columns)))
        )
    }

    /// Infinite canvases share a 128pt world grid and differ only in zoom ceiling.
    var infiniteCanvasMaximumScale: CGFloat {
        isInfiniteCanvas ? iconPointSize / 128 : 1
    }

    /// Sprite size before the infinite-canvas transform is applied.
    var layoutIconPointSize: CGFloat {
        isInfiniteCanvas ? 128 : iconPointSize
    }
}

/// World-space geometry for the non-paged 16 × N canvas. Its unscaled cell
/// pitch deliberately matches the existing 6 × 4 layout.
struct InfiniteCanvasMetrics {
    static let columns = 16
    static let panBoundaryPadding: CGFloat = 200

    let size: CGSize
    let itemCount: Int
    let columnCount: Int
    let rows: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let worldSize: CGSize
    let viewportCenter: CGPoint
    let availableSize: CGSize
    let maximumScale: CGFloat

    private let centersIncompleteLastRow: Bool

    init(
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

    var fittedScale: CGFloat {
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
    var viewportFillingScale: CGFloat {
        min(
            maximumScale,
            1.06 * max(
                availableSize.width / max(worldSize.width, 1),
                availableSize.height / max(worldSize.height, 1)
            )
        )
    }

    func worldCenter(globalIndex: Double) -> CGPoint {
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

    func screenCenter(globalIndex: Double, scale: CGFloat, pan: CGPoint) -> CGPoint {
        let world = worldCenter(globalIndex: globalIndex)
        return CGPoint(
            x: viewportCenter.x + pan.x + (world.x - worldSize.width * 0.5) * scale,
            y: viewportCenter.y + pan.y + (world.y - worldSize.height * 0.5) * scale
        )
    }

    func itemIndex(atTopLeftPoint point: CGPoint, scale: CGFloat, pan: CGPoint) -> Int? {
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

    func clampedPan(_ proposed: CGPoint, scale: CGFloat) -> CGPoint {
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

struct GridMetrics {
    static var columns: Int { current.columns }
    static var rows: Int { current.rows }
    static var pageCapacity: Int { columns * rows }

    private static var current: GridLayoutPreset { GridLayoutPreset.current }

    /// Display size of each app icon in points.
    static var iconPointSize: CGFloat { current.layoutIconPointSize }

    let size: CGSize
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let gridWidth: CGFloat
    let gridHeight: CGFloat
    let gridLeft: CGFloat
    let gridTop: CGFloat
    let iconSize: CGFloat

    init(size: CGSize) {
        self.size = size
        iconSize = Self.iconPointSize

        // Horizontal: 128pt icon + breathing room for 6 columns on typical displays.
        let hInset: CGFloat = 80
        let availableWidth = max(size.width - hInset * 2, 1)
        let minGap: CGFloat = 28
        let idealCell = availableWidth / CGFloat(Self.columns)
        let maxCellWidth = max(220, iconSize + minGap)
        let unscaledCellWidth = min(max(idealCell, iconSize + minGap), maxCellWidth)
        cellWidth = iconSize
            + (unscaledCellWidth - iconSize) * Self.current.spacingScale

        // Vertical: icon + label (~22) + gap.
        let vInsetTop: CGFloat = 120
        let vInsetBottom: CGFloat = 96
        let availableHeight = max(size.height - vInsetTop - vInsetBottom, 1)
        let idealRow = availableHeight / CGFloat(Self.rows)
        let maxCellHeight = max(220, iconSize + 48)
        let unscaledCellHeight = min(max(idealRow, iconSize + 48), maxCellHeight)
        cellHeight = iconSize
            + (unscaledCellHeight - iconSize) * Self.current.spacingScale

        gridWidth = cellWidth * CGFloat(Self.columns)
        gridHeight = cellHeight * CGFloat(Self.rows)
        gridLeft = (size.width - gridWidth) / 2
        // Prefer optical center slightly above geometric center (search field above).
        gridTop = max(vInsetTop, (size.height - gridHeight) / 2 - 12)
    }

    /// Icon center in **top-left** coordinates (y grows downward). Used by Metal.
    func iconCenter(localIndex: Int, page: Int, pageOffset: Double) -> CGPoint {
        iconCenter(localIndex: Double(localIndex), page: page, pageOffset: pageOffset)
    }

    /// Icon center for a fractional local index. Interpolating the cell center
    /// instead of rounding the index keeps reorder animations smooth across
    /// columns and rows.
    func iconCenter(localIndex: Double, page: Int, pageOffset: Double) -> CGPoint {
        let lowerIndex = max(0, Int(floor(localIndex)))
        let upperIndex = min(Self.pageCapacity - 1, Int(ceil(localIndex)))
        let fraction = CGFloat(localIndex - floor(localIndex))
        let lower = iconCenter(integerLocalIndex: lowerIndex, page: page, pageOffset: pageOffset)
        let upper = iconCenter(integerLocalIndex: upperIndex, page: page, pageOffset: pageOffset)
        return CGPoint(
            x: lower.x + (upper.x - lower.x) * fraction,
            y: lower.y + (upper.y - lower.y) * fraction
        )
    }

    /// Icon center for a fractional position in the complete app catalog.
    /// This allows an item crossing a page boundary to travel continuously.
    func iconCenter(globalIndex: Double, pageOffset: Double) -> CGPoint {
        let lowerIndex = max(0, Int(floor(globalIndex)))
        let upperIndex = max(lowerIndex, Int(ceil(globalIndex)))
        let fraction = CGFloat(globalIndex - floor(globalIndex))
        let lower = iconCenter(
            localIndex: lowerIndex % Self.pageCapacity,
            page: lowerIndex / Self.pageCapacity,
            pageOffset: pageOffset
        )
        let upper = iconCenter(
            localIndex: upperIndex % Self.pageCapacity,
            page: upperIndex / Self.pageCapacity,
            pageOffset: pageOffset
        )
        return CGPoint(
            x: lower.x + (upper.x - lower.x) * fraction,
            y: lower.y + (upper.y - lower.y) * fraction
        )
    }

    private func iconCenter(integerLocalIndex: Int, page: Int, pageOffset: Double) -> CGPoint {
        let column = integerLocalIndex % Self.columns
        let row = integerLocalIndex / Self.columns
        let pageShift = CGFloat(Double(page) - pageOffset) * size.width
        return CGPoint(
            x: gridLeft + cellWidth * (CGFloat(column) + 0.5) + pageShift,
            y: gridTop + cellHeight * (CGFloat(row) + 0.5)
        )
    }

    func labelCenter(localIndex: Int, page: Int, pageOffset: Double) -> CGPoint {
        let center = iconCenter(localIndex: localIndex, page: page, pageOffset: pageOffset)
        return CGPoint(x: center.x, y: center.y + iconSize * 0.5 + 16)
    }

    /// Hit-test using AppKit bottom-left point converted to top-left space.
    func hitTest(
        point: CGPoint,
        pageOffset: Double,
        hitRadiusScale: CGFloat = 0.62
    ) -> (page: Int, localIndex: Int)? {
        let topPoint = CGPoint(x: point.x, y: size.height - point.y)

        // Find nearest page whose grid could contain this x.
        let relative = (topPoint.x - gridLeft) / max(size.width, 1) + pageOffset
        let page = Int(floor(relative + 1e-6))
        guard page >= 0 else { return nil }

        let pageShift = CGFloat(Double(page) - pageOffset) * size.width
        let localX = topPoint.x - gridLeft - pageShift
        let localY = topPoint.y - gridTop
        let column = Int(floor(localX / cellWidth))
        let row = Int(floor(localY / cellHeight))
        guard row >= 0, row < Self.rows, column >= 0, column < Self.columns else { return nil }

        // Require hit near the icon (not the entire cell).
        let iconCx = cellWidth * (CGFloat(column) + 0.5)
        let iconCy = cellHeight * (CGFloat(row) + 0.5)
        let dx = localX - iconCx
        let dy = localY - iconCy
        let hitRadius = iconSize * hitRadiusScale
        guard (dx * dx + dy * dy) <= hitRadius * hitRadius else { return nil }
        return (page, row * Self.columns + column)
    }
}
