import Foundation

public struct LaunchpadLayoutProfile: Equatable, Identifiable, Sendable, Codable, Hashable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct LaunchpadLayoutProfileIndex: Equatable, Sendable, Codable {
    public var activeID: String
    public var profiles: [LaunchpadLayoutProfile]

    public init(activeID: String, profiles: [LaunchpadLayoutProfile]) {
        self.activeID = activeID
        self.profiles = profiles
    }

    public static var `default`: Self {
        Self(
            activeID: LaunchpadLayoutProfileStore.defaultProfileID,
            profiles: [
                LaunchpadLayoutProfile(
                    id: LaunchpadLayoutProfileStore.defaultProfileID,
                    name: LaunchpadLayoutProfileStore.defaultProfileName
                )
            ]
        )
    }
}

public enum LaunchpadLayoutProfileError: Error, Equatable, LocalizedError {
    case invalidProfileID(String)
    case defaultProfileProtected
    case profileNotFound(String)
    case emptyName
    case missingDocument(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfileID:
            return "无效的布局。"
        case .defaultProfileProtected:
            return "不能删除默认布局。"
        case .profileNotFound:
            return "找不到该布局。"
        case .emptyName:
            return "请输入布局名称。"
        case .missingDocument:
            return "找不到该布局文件。"
        }
    }
}

public enum LaunchpadLayoutProfileStore {
    public static let defaultProfileID = "default"
    public static let defaultProfileName = "默认"
    public static let maxNameScalars = 80

    public static func layoutsDirectory(domain: String) -> URL {
        LaunchpadPreferenceStore.layoutSupportDirectory(domain: domain)
            .appendingPathComponent("layouts", isDirectory: true)
    }

    public static func isValidProfileID(_ id: String) -> Bool {
        id == defaultProfileID || UUID(uuidString: id) != nil
    }

    public static func canDelete(_ id: String) -> Bool {
        id != defaultProfileID && isValidProfileID(id)
    }

    public static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.unicodeScalars.contains(where: { $0.value == 0 }) {
            return nil
        }
        if trimmed.unicodeScalars.count <= maxNameScalars {
            return trimmed
        }
        let end = trimmed.unicodeScalars.index(
            trimmed.unicodeScalars.startIndex,
            offsetBy: maxNameScalars
        )
        let clipped = String(trimmed.unicodeScalars[..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.isEmpty ? nil : clipped
    }

    public static func suggestedNewName(existing: [LaunchpadLayoutProfile]) -> String {
        let taken = Set(existing.map(\.name))
        if !taken.contains("新布局") {
            return "新布局"
        }
        var index = 2
        while taken.contains("新布局 \(index)") {
            index += 1
        }
        return "新布局 \(index)"
    }

    public static func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("index.json", isDirectory: false)
    }

    public static func documentURL(in directory: URL, profileID: String) throws -> URL {
        guard isValidProfileID(profileID) else {
            throw LaunchpadLayoutProfileError.invalidProfileID(profileID)
        }
        return directory.appendingPathComponent("\(profileID).json", isDirectory: false)
    }

    public static func loadIndex(in directory: URL) -> LaunchpadLayoutProfileIndex {
        let url = indexURL(in: directory)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(LaunchpadLayoutProfileIndex.self, from: data)
        else {
            return .default
        }
        return normalized(decoded)
    }

    public static func loadIndex(domain: String) -> LaunchpadLayoutProfileIndex {
        loadIndex(in: layoutsDirectory(domain: domain))
    }

    public static func saveIndex(_ index: LaunchpadLayoutProfileIndex, in directory: URL) throws {
        let normalizedIndex = normalized(index)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalizedIndex)
        try data.write(to: indexURL(in: directory), options: .atomic)
    }

    public static func readDocument(
        in directory: URL,
        profileID: String
    ) throws -> LaunchpadLayoutDocument {
        let url = try documentURL(in: directory, profileID: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LaunchpadLayoutProfileError.missingDocument(profileID)
        }
        let data = try Data(contentsOf: url)
        try LaunchpadLayoutImporter.validateJSONSize(data)
        let document = try LaunchpadLayoutDocument.makeDecoder().decode(
            LaunchpadLayoutDocument.self,
            from: data
        )
        try LaunchpadLayoutImporter.validate(document)
        return document
    }

    public static func writeDocument(
        _ document: LaunchpadLayoutDocument,
        in directory: URL,
        profileID: String
    ) throws {
        let url = try documentURL(in: directory, profileID: profileID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try LaunchpadLayoutDocument.makeEncoder(pretty: true).encode(document)
        try data.write(to: url, options: .atomic)
    }

    public static func removeDocument(in directory: URL, profileID: String) throws {
        guard canDelete(profileID) else {
            throw LaunchpadLayoutProfileError.defaultProfileProtected
        }
        let url = try documentURL(in: directory, profileID: profileID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func normalized(_ index: LaunchpadLayoutProfileIndex) -> LaunchpadLayoutProfileIndex {
        var profiles = index.profiles.filter { profile in
            isValidProfileID(profile.id) && normalizedName(profile.name) != nil
        }
        if let defaultIndex = profiles.firstIndex(where: { $0.id == defaultProfileID }) {
            if defaultIndex != 0 {
                let defaultProfile = profiles.remove(at: defaultIndex)
                profiles.insert(defaultProfile, at: 0)
            }
        } else {
            profiles.insert(
                LaunchpadLayoutProfile(id: defaultProfileID, name: defaultProfileName),
                at: 0
            )
        }
        let activeID = profiles.contains(where: { $0.id == index.activeID })
            ? index.activeID
            : defaultProfileID
        return LaunchpadLayoutProfileIndex(activeID: activeID, profiles: profiles)
    }
}
