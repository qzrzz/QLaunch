import Foundation

public enum LaunchpadAutoLayoutKind: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case recentlyUsed
    case nameAscending
    case nameDescending
    case installDateAscending
    case installDateDescending
    case iconColor

    public var id: Self { self }

    public var title: String {
        switch self {
        case .recentlyUsed: "最近使用"
        case .nameAscending: "名称正序"
        case .nameDescending: "名称倒序"
        case .installDateAscending: "安装时间正序"
        case .installDateDescending: "安装时间倒序"
        case .iconColor: "按图标颜色排序"
        }
    }

    /// Phrase used when an automatic grid blocks drag-to-reorder.
    public var sortingPhrase: String {
        switch self {
        case .recentlyUsed: "按最近使用排序"
        case .nameAscending, .nameDescending: "按名称排序"
        case .installDateAscending, .installDateDescending: "按安装时间排序"
        case .iconColor: "按图标颜色排序"
        }
    }

    public var dragHintMessage: String {
        "当前在\(sortingPhrase)，如果要拖拽排序，在空白处右键选择用户布局"
    }
}

public enum LaunchpadLayoutMode: Equatable, Sendable {
    case user
    case auto(LaunchpadAutoLayoutKind)

    public var isUser: Bool {
        if case .user = self { return true }
        return false
    }

    public var storageValue: String {
        switch self {
        case .user:
            return "user"
        case .auto(let kind):
            return "auto.\(kind.rawValue)"
        }
    }

    public init(storageValue: String?) {
        guard let storageValue, storageValue.hasPrefix("auto.") else {
            self = .user
            return
        }
        let raw = String(storageValue.dropFirst("auto.".count))
        if let kind = LaunchpadAutoLayoutKind(rawValue: raw) {
            self = .auto(kind)
        } else {
            self = .user
        }
    }
}

public enum LaunchpadLayoutSelectorID {
    public static func user(_ profileID: String) -> String {
        "user:\(profileID)"
    }

    public static func auto(_ kind: LaunchpadAutoLayoutKind) -> String {
        "auto:\(kind.rawValue)"
    }

    public static func parse(_ raw: String) -> (profileID: String?, autoKind: LaunchpadAutoLayoutKind?) {
        if raw.hasPrefix("user:") {
            return (String(raw.dropFirst("user:".count)), nil)
        }
        if raw.hasPrefix("auto:") {
            let kind = LaunchpadAutoLayoutKind(rawValue: String(raw.dropFirst("auto:".count)))
            return (nil, kind)
        }
        return (nil, nil)
    }
}

public struct LaunchpadIconColor: Equatable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double
    public var isChromatic: Bool

    public init(hue: Double, saturation: Double, brightness: Double, isChromatic: Bool) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.isChromatic = isChromatic
    }
}

public struct LaunchpadAutoLayoutApp: Equatable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var lastUsedAt: Date?
    public var installedAt: Date?
    public var color: LaunchpadIconColor?

    public init(
        id: String,
        name: String,
        path: String,
        lastUsedAt: Date? = nil,
        installedAt: Date? = nil,
        color: LaunchpadIconColor? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.lastUsedAt = lastUsedAt
        self.installedAt = installedAt
        self.color = color
    }
}

public enum LaunchpadAutoLayoutSorter {
    public static func sortedIDs(
        _ apps: [LaunchpadAutoLayoutApp],
        kind: LaunchpadAutoLayoutKind
    ) -> [String] {
        apps.sorted { lhs, rhs in
            compare(lhs, rhs, kind: kind)
        }.map(\.id)
    }

    /// Cancellable bottom-up merge sort used by background materialization.
    /// Cancellation is checked between small comparison batches, so abandoning
    /// a stale layout does not leave a full localized sort consuming CPU.
    public static func sortedIDs(
        _ apps: [LaunchpadAutoLayoutApp],
        kind: LaunchpadAutoLayoutKind,
        cancellationCheck: @Sendable () -> Bool
    ) -> [String]? {
        guard !cancellationCheck() else { return nil }
        guard apps.count > 1 else { return apps.map(\.id) }

        var source = apps
        var destination = apps
        var width = 1
        var comparisonCount = 0

        while width < source.count {
            var start = 0
            while start < source.count {
                guard !cancellationCheck() else { return nil }
                let middle = min(start + width, source.count)
                let end = min(start + width * 2, source.count)
                var left = start
                var right = middle
                var output = start

                while left < middle, right < end {
                    comparisonCount &+= 1
                    if comparisonCount & 63 == 0, cancellationCheck() { return nil }
                    if compare(source[right], source[left], kind: kind) {
                        destination[output] = source[right]
                        right += 1
                    } else {
                        destination[output] = source[left]
                        left += 1
                    }
                    output += 1
                }
                while left < middle {
                    destination[output] = source[left]
                    left += 1
                    output += 1
                }
                while right < end {
                    destination[output] = source[right]
                    right += 1
                    output += 1
                }
                start = end
            }
            swap(&source, &destination)
            width *= 2
        }
        return cancellationCheck() ? nil : source.map(\.id)
    }

    public static func compare(
        _ lhs: LaunchpadAutoLayoutApp,
        _ rhs: LaunchpadAutoLayoutApp,
        kind: LaunchpadAutoLayoutKind
    ) -> Bool {
        switch kind {
        case .recentlyUsed:
            return compareDates(lhs.lastUsedAt, rhs.lastUsedAt, ascending: false, lhs: lhs, rhs: rhs)
        case .nameAscending:
            return compareName(lhs, rhs, ascending: true)
        case .nameDescending:
            return compareName(lhs, rhs, ascending: false)
        case .installDateAscending:
            return compareDates(lhs.installedAt, rhs.installedAt, ascending: true, lhs: lhs, rhs: rhs)
        case .installDateDescending:
            return compareDates(lhs.installedAt, rhs.installedAt, ascending: false, lhs: lhs, rhs: rhs)
        case .iconColor:
            return compareColor(lhs, rhs)
        }
    }

    private static func compareName(
        _ lhs: LaunchpadAutoLayoutApp,
        _ rhs: LaunchpadAutoLayoutApp,
        ascending: Bool
    ) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return ascending ? nameOrder == .orderedAscending : nameOrder == .orderedDescending
        }
        return lhs.path < rhs.path
    }

    private static func compareDates(
        _ lhsDate: Date?,
        _ rhsDate: Date?,
        ascending: Bool,
        lhs: LaunchpadAutoLayoutApp,
        rhs: LaunchpadAutoLayoutApp
    ) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (left?, right?):
            if left != right {
                return ascending ? left < right : left > right
            }
            return compareName(lhs, rhs, ascending: true)
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return compareName(lhs, rhs, ascending: true)
        }
    }

    private static func compareColor(
        _ lhs: LaunchpadAutoLayoutApp,
        _ rhs: LaunchpadAutoLayoutApp
    ) -> Bool {
        let leftChromatic = lhs.color?.isChromatic == true
        let rightChromatic = rhs.color?.isChromatic == true
        if leftChromatic != rightChromatic {
            return leftChromatic && !rightChromatic
        }
        if leftChromatic, let left = lhs.color, let right = rhs.color {
            if abs(left.hue - right.hue) > 0.0001 {
                return left.hue < right.hue
            }
            if abs(left.saturation - right.saturation) > 0.0001 {
                return left.saturation > right.saturation
            }
        } else if let left = lhs.color, let right = rhs.color {
            if abs(left.brightness - right.brightness) > 0.0001 {
                return left.brightness < right.brightness
            }
        } else if lhs.color == nil || rhs.color == nil {
            if lhs.color != nil { return true }
            if rhs.color != nil { return false }
        }
        return compareName(lhs, rhs, ascending: true)
    }
}
