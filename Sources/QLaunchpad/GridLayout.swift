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
    static let canvasHoverMagnificationKey = "canvasHoverMagnification"
    static let defaultCanvasHoverMagnification = true

    static var canvasHoverMagnificationEnabled: Bool {
        UserDefaults.standard.object(forKey: canvasHoverMagnificationKey) as? Bool
            ?? defaultCanvasHoverMagnification
    }
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
        case .infiniteCanvas, .infiniteCanvas256: InfiniteCanvasMetrics.maximumColumns
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

    init(size: CGSize, minimumGridTop: CGFloat) {
        self.size = size
        let requestedIconSize = Self.iconPointSize
        let vertical = Self.verticalPlacement(
            screenHeight: size.height, iconSize: requestedIconSize, minimumGridTop: minimumGridTop
        )
        let availableHeight = max(size.height - vertical.insetTop - vertical.insetBottom, 1)
        let idealRow = availableHeight / CGFloat(Self.rows)
        let extraLabelHeight = AppLabelSize.current.pointSize - AppLabelSize.defaultSize.pointSize
        let labelGap = min(26, vertical.minCellExtra * Self.current.spacingScale) + extraLabelHeight
        iconSize = vertical.centerInChromeBand && !Self.current.isInfiniteCanvas
            ? min(requestedIconSize, max(1, idealRow - labelGap))
            : requestedIconSize

        // Horizontal: 128pt icon + breathing room for 6 columns on typical displays.
        let hInset: CGFloat = 80
        let availableWidth = max(size.width - hInset * 2, 1)
        let minGap: CGFloat = 28
        let idealCell = availableWidth / CGFloat(Self.columns)
        let maxCellWidth = max(220, iconSize + minGap)
        let unscaledCellWidth = min(max(idealCell, iconSize + minGap), maxCellWidth)
        cellWidth = iconSize
            + (unscaledCellWidth - iconSize) * Self.current.spacingScale

        let unscaledCellHeight = min(
            max(idealRow, iconSize + vertical.minCellExtra + extraLabelHeight),
            vertical.maxCell
        )
        let preferredCellHeight = iconSize
            + (unscaledCellHeight - iconSize) * Self.current.spacingScale
        cellHeight = vertical.centerInChromeBand
            ? max(iconSize, min(preferredCellHeight, idealRow))
            : preferredCellHeight

        gridWidth = cellWidth * CGFloat(Self.columns)
        gridHeight = cellHeight * CGFloat(Self.rows)
        gridLeft = (size.width - gridWidth) / 2
        if vertical.centerInChromeBand {
            gridTop = Self.centeredGridTop(
                screenHeight: size.height,
                gridHeight: gridHeight,
                cellHeight: cellHeight,
                iconSize: iconSize,
                placement: vertical
            )
        } else {
            // Prefer optical center slightly above geometric center (search field above).
            gridTop = max(vertical.insetTop, (size.height - gridHeight) / 2 - vertical.opticalLift)
        }
    }

    /// Comfortable padding on large displays. 7×5 128pt on a 13" built-in
    /// (~1440×900 / 1470×956) cannot keep that padding and still sit in the
    /// band between the search field and the page dots.
    private struct VerticalPlacement {
        var insetTop: CGFloat
        var insetBottom: CGFloat
        var minCellExtra: CGFloat
        var maxCell: CGFloat
        var opticalLift: CGFloat
        var centerInChromeBand: Bool
    }

    private static func verticalPlacement(
        screenHeight: CGFloat,
        iconSize: CGFloat,
        minimumGridTop: CGFloat
    ) -> VerticalPlacement {
        let comfortable = VerticalPlacement(
            insetTop: max(120, minimumGridTop),
            insetBottom: 96,
            minCellExtra: 48,
            maxCell: max(220, iconSize + 48),
            opticalLift: 12,
            centerInChromeBand: false
        )
        let comfortableBlock = (iconSize + comfortable.minCellExtra * current.spacingScale) * CGFloat(rows)
            + comfortable.insetTop
            + comfortable.insetBottom
        guard screenHeight + 0.5 < comfortableBlock else { return comfortable }

        let chromeBottom = LaunchpadPageIndicatorHitArea.bottomInset
            + LaunchpadPageIndicatorHitArea.dotHeight
            + LaunchpadPageIndicatorHitArea.verticalPadding * 2
        return VerticalPlacement(
            insetTop: minimumGridTop,
            insetBottom: chromeBottom,
            minCellExtra: 40,
            maxCell: comfortable.maxCell,
            opticalLift: 8,
            centerInChromeBand: true
        )
    }

    /// Center the grid, then lift it slightly for the search field. If the
    /// block is taller than the chrome-safe band, pin under the search field
    /// instead of the old 120pt floor (which left 7×5 sitting too low).
    private static func centeredGridTop(
        screenHeight: CGFloat,
        gridHeight: CGFloat,
        cellHeight: CGFloat,
        iconSize: CGFloat,
        placement: VerticalPlacement
    ) -> CGFloat {
        let opticalTop = (screenHeight - gridHeight) / 2 - placement.opticalLift
        let minTop = placement.insetTop - cellHeight * 0.5 + iconSize * 0.5
        let maxTop = screenHeight - placement.insetBottom - gridHeight
        if maxTop + 0.5 < minTop {
            return minTop
        }
        return min(max(opticalTop, minTop), maxTop)
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
