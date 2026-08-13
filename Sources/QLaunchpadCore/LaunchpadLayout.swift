import Foundation

public enum LaunchpadLayoutKind {
    public static let current = "qlaunchpad.layout"
    public static let schemaVersion = 1
}

public struct LaunchpadLayoutDocument: Equatable, Sendable {
    public var kind: String
    public var schemaVersion: Int
    public var exportedAt: Date?
    public var appVersion: String?
    public var grid: LaunchpadLayoutGrid?
    public var items: [LaunchpadLayoutItem]
    public var hidden: [String]?
    public var catalog: [LaunchpadLayoutCatalogEntry]?

    public init(
        kind: String = LaunchpadLayoutKind.current,
        schemaVersion: Int = LaunchpadLayoutKind.schemaVersion,
        exportedAt: Date? = nil,
        appVersion: String? = nil,
        grid: LaunchpadLayoutGrid? = nil,
        items: [LaunchpadLayoutItem],
        hidden: [String]? = nil,
        catalog: [LaunchpadLayoutCatalogEntry]? = nil
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.grid = grid
        self.items = items
        self.hidden = hidden
        self.catalog = catalog
    }

    /// Pretty + sortedKeys + ISO-8601. Not the on-disk folders encoder.
    public static func makeEncoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if pretty {
            formatting.insert(.prettyPrinted)
        }
        encoder.outputFormatting = formatting
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum LaunchpadLayoutItem: Equatable, Sendable {
    case app(id: String)
    case folder(id: String?, name: String, apps: [String])
}

public struct LaunchpadLayoutGrid: Codable, Equatable, Sendable {
    public var preset: String
    public var columns: Int
    public var rows: Int
    public var pageCapacity: Int

    public init(preset: String, columns: Int, rows: Int, pageCapacity: Int) {
        self.preset = preset
        self.columns = columns
        self.rows = rows
        self.pageCapacity = pageCapacity
    }
}

public struct LaunchpadLayoutCatalogEntry: Codable, Equatable, Sendable {
    public var id: String
    public var bundleIdentifier: String
    public var name: String
    public var path: String?

    public init(id: String, bundleIdentifier: String, name: String, path: String? = nil) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
    }
}

public struct LaunchpadKnownApp: Equatable, Sendable {
    public var id: String
    public var bundleIdentifier: String
    public var name: String
    public var path: String

    public init(id: String, bundleIdentifier: String, name: String, path: String) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
    }
}

public enum LaunchpadLayoutImportMode: String, Sendable {
    case merge
    case replace
}

public struct LaunchpadLayoutReport: Equatable, Sendable {
    public var importedRootItems: Int
    public var importedFolders: Int
    public var resolvedApps: Int
    public var skippedUnknown: [String]
    public var appendedLeftover: [String]
    public var hiddenReplaced: Bool
    public var unhiddenByClaim: [String]
    public var newlyHiddenByReplace: [String]

    public init(
        importedRootItems: Int,
        importedFolders: Int,
        resolvedApps: Int,
        skippedUnknown: [String],
        appendedLeftover: [String],
        hiddenReplaced: Bool,
        unhiddenByClaim: [String],
        newlyHiddenByReplace: [String]
    ) {
        self.importedRootItems = importedRootItems
        self.importedFolders = importedFolders
        self.resolvedApps = resolvedApps
        self.skippedUnknown = skippedUnknown
        self.appendedLeftover = appendedLeftover
        self.hiddenReplaced = hiddenReplaced
        self.unhiddenByClaim = unhiddenByClaim
        self.newlyHiddenByReplace = newlyHiddenByReplace
    }
}

public enum LaunchpadLayoutError: Error, Equatable {
    case invalidKind(String)
    case unsupportedSchemaVersion(Int)
    case malformed(String)
    case limitExceeded(String)
    case duplicateID(String)
    case nestedFolder(String)
    case itemHiddenOverlap(String)
    case strictUnresolved([String])
}

extension LaunchpadLayoutDocument: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion
        case exportedAt
        case appVersion
        case grid
        case items
        case hidden
        case catalog
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        grid = try container.decodeIfPresent(LaunchpadLayoutGrid.self, forKey: .grid)
        items = try container.decode([LaunchpadLayoutItem].self, forKey: .items)
        hidden = try container.decodeIfPresent([String].self, forKey: .hidden)
        catalog = try container.decodeIfPresent([LaunchpadLayoutCatalogEntry].self, forKey: .catalog)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(exportedAt, forKey: .exportedAt)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        try container.encodeIfPresent(grid, forKey: .grid)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(hidden, forKey: .hidden)
        try container.encodeIfPresent(catalog, forKey: .catalog)
    }
}

extension LaunchpadLayoutItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case name
        case apps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "app":
            self = .app(id: try container.decode(String.self, forKey: .id))
        case "folder":
            self = .folder(
                id: try container.decodeIfPresent(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                apps: try container.decode([String].self, forKey: .apps)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported layout item type '\(type)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let id):
            try container.encode("app", forKey: .type)
            try container.encode(id, forKey: .id)
        case .folder(let id, let name, let apps):
            try container.encode("folder", forKey: .type)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(apps, forKey: .apps)
        }
    }
}
