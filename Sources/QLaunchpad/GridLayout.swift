import CoreGraphics
import Foundation
import QLaunchpadCore

/// Layout metrics for a Launchpad-style icon grid.
/// Icon texture pixel size is `iconPointSize * IconRenderQuality.current.rasterScale`
/// (4× quality, 2× performance / low memory).
enum GridLayoutPreset: String, CaseIterable, Identifiable {
    case fourByTwo = "4x2-256"
    case fiveByFour = "5x4-128"
    case sixByFour = "6x4-128"
    case sevenByFive = "7x5-128"

    static let defaultsKey = LaunchpadPersistence.gridLayoutPresetKey
    static let defaultPreset: Self = .sixByFour

    var id: Self { self }

    var columns: Int {
        switch self {
        case .fourByTwo: 4
        case .fiveByFour: 5
        case .sixByFour: 6
        case .sevenByFive: 7
        }
    }

    var rows: Int {
        switch self {
        case .fourByTwo: 2
        case .fiveByFour, .sixByFour: 4
        case .sevenByFive: 5
        }
    }

    var title: String {
        switch self {
        case .fourByTwo: "4 × 2 (256pt)"
        case .fiveByFour: "5 × 4 (128pt)"
        case .sixByFour: "6 × 4 (128pt)"
        case .sevenByFive: "7 × 5 (128pt)"
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
        case .fourByTwo: 256
        case .fiveByFour, .sixByFour, .sevenByFive: 128
        }
    }
}

struct GridMetrics {
    static var columns: Int { current.columns }
    static var rows: Int { current.rows }
    static var pageCapacity: Int { columns * rows }

    private static var current: GridLayoutPreset { GridLayoutPreset.current }

    /// Display size of each app icon in points.
    static var iconPointSize: CGFloat { current.iconPointSize }

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
        cellWidth = min(max(idealCell, iconSize + minGap), maxCellWidth)

        // Vertical: icon + label (~22) + gap.
        let vInsetTop: CGFloat = 120
        let vInsetBottom: CGFloat = 96
        let availableHeight = max(size.height - vInsetTop - vInsetBottom, 1)
        let idealRow = availableHeight / CGFloat(Self.rows)
        let maxCellHeight = max(220, iconSize + 48)
        cellHeight = min(max(idealRow, iconSize + 48), maxCellHeight)

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
