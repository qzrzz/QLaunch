import CoreGraphics

public enum LaunchpadSearchFieldSize: String, CaseIterable, Sendable {
    case compact
    case standard
    case large

    public static let defaultsKey = "launchpadSearchFieldSize"
    public static let defaultSize: Self = .standard

    public var dimensions: CGSize {
        switch self {
        case .compact: CGSize(width: 320, height: 38)
        case .standard: CGSize(width: 420, height: 48)
        case .large: CGSize(width: 520, height: 58)
        }
    }

    public var fontSize: CGFloat {
        switch self {
        case .compact: 16
        case .standard: 18
        case .large: 20
        }
    }
}

public struct LaunchpadSearchFieldLayout: Equatable, Sendable {
    private static let horizontalHitSlop: CGFloat = 48
    private static let verticalHitSlop: CGFloat = 12

    public let topInset: CGFloat
    public let size: CGSize
    public let fontSize: CGFloat
    public let hitSize: CGSize

    public init(
        preset: LaunchpadSearchFieldSize = .defaultSize,
        availableWidth: CGFloat = .greatestFiniteMagnitude,
        displaySafeTop: CGFloat = 0
    ) {
        topInset = max(46, displaySafeTop + 16)
        size = CGSize(
            width: min(preset.dimensions.width, max(1, availableWidth - 32)),
            height: preset.dimensions.height
        )
        fontSize = preset.fontSize
        hitSize = CGSize(
            width: min(size.width + Self.horizontalHitSlop * 2, max(1, availableWidth)),
            height: size.height + Self.verticalHitSlop * 2
        )
    }

    public var minimumGridTop: CGFloat {
        topInset + size.height + Self.verticalHitSlop + 6
    }

    public func hitRect(in bounds: CGRect, flipped: Bool = false) -> CGRect {
        let top = topInset - Self.verticalHitSlop
        let y = flipped ? bounds.minY + top : bounds.maxY - top - hitSize.height
        return CGRect(
            x: bounds.midX - hitSize.width / 2,
            y: y,
            width: hitSize.width,
            height: hitSize.height
        )
    }
}
