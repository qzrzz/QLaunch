import CoreGraphics
import Foundation

/// Geometry of the 3 × 3 mini-icons composited into a folder tile.
/// Metal open/close animation and the baked preview texture share these ratios
/// so icons appear to fly out of the same slots they occupied on the icon.
public enum FolderPreviewLayout {
    public static let columns = 3
    public static let capacity = 9
    public static let miniSizeRatio: CGFloat = 22.0 / 128.0
    public static let gapRatio: CGFloat = 4.0 / 128.0

    public static func miniSize(in folderSize: CGFloat) -> CGFloat {
        folderSize * miniSizeRatio
    }

    public static func gap(in folderSize: CGFloat) -> CGFloat {
        folderSize * gapRatio
    }

    public static func contentSize(in folderSize: CGFloat) -> CGFloat {
        let mini = miniSize(in: folderSize)
        let gap = gap(in: folderSize)
        return mini * CGFloat(columns) + gap * CGFloat(columns - 1)
    }

    /// Center of a preview slot inside a square folder.
    ///
    /// - Parameter yIncreasesDown: Metal view space is top-left (true). A
    ///   CoreGraphics bitmap context is bottom-left (false).
    public static func miniCenter(
        index: Int,
        folderCenter: CGPoint,
        folderSize: CGFloat,
        yIncreasesDown: Bool
    ) -> CGPoint {
        let mini = miniSize(in: folderSize)
        let spacing = mini + gap(in: folderSize)
        let content = contentSize(in: folderSize)
        let column = CGFloat(index % columns)
        let x = folderCenter.x - content * 0.5 + column * spacing + mini * 0.5
        if yIncreasesDown {
            let rowFromTop = CGFloat(index / columns)
            let y = folderCenter.y - content * 0.5 + rowFromTop * spacing + mini * 0.5
            return CGPoint(x: x, y: y)
        }
        let rowFromBottom = CGFloat((columns - 1) - index / columns)
        let y = folderCenter.y - content * 0.5 + rowFromBottom * spacing + mini * 0.5
        return CGPoint(x: x, y: y)
    }
}
