import CoreFoundation
import Foundation

public struct LaunchpadPersistedLayout: Equatable, Sendable {
    public var itemOrder: [String]
    public var foldersData: Data
    public var hiddenIDs: [String]

    public init(itemOrder: [String], foldersData: Data, hiddenIDs: [String]) {
        self.itemOrder = itemOrder
        self.foldersData = foldersData
        self.hiddenIDs = hiddenIDs
    }
}

public enum LaunchpadPreferenceStore {
    public static let releaseDomain = "com.qzrzz.qlaunchpad"
    public static let developmentDomain = "com.qzrzz.qlaunchpad.dev"

    public static func encodeFolders(_ folders: [AppFolder]) throws -> Data {
        try LaunchpadPersistence.encodeFolders(folders)
    }

    public static func decodeFolders(_ data: Data) throws -> [AppFolder] {
        try LaunchpadPersistence.decodeFolders(data)
    }

    /// Synchronizes the domain, then copies the three layout keys. Missing keys
    /// are empty arrays / empty `Data`.
    public static func readLayout(domain: String) -> LaunchpadPersistedLayout {
        let applicationID = domain as CFString
        CFPreferencesAppSynchronize(applicationID)
        return LaunchpadPersistedLayout(
            itemOrder: copyStringArray(key: LaunchpadPersistence.itemOrderKey, applicationID: applicationID),
            foldersData: copyData(key: LaunchpadPersistence.foldersKey, applicationID: applicationID),
            hiddenIDs: copyStringArray(key: LaunchpadPersistence.hiddenAppsKey, applicationID: applicationID)
        )
    }

    /// Writes only keys that differ. Hidden is sorted before compare / set.
    /// Folders must be `CFData` (encoded `[AppFolder]` bytes), not a JSON string.
    public static func writeLayout(domain: String, _ layout: LaunchpadPersistedLayout) {
        let applicationID = domain as CFString
        let next = LaunchpadPersistedLayout(
            itemOrder: layout.itemOrder,
            foldersData: layout.foldersData,
            hiddenIDs: layout.hiddenIDs.sorted()
        )
        let current = readLayout(domain: domain)
        var changed = false

        if next.itemOrder != current.itemOrder {
            CFPreferencesSetAppValue(
                LaunchpadPersistence.itemOrderKey as CFString,
                next.itemOrder as CFArray,
                applicationID
            )
            changed = true
        }
        if next.foldersData != current.foldersData {
            CFPreferencesSetAppValue(
                LaunchpadPersistence.foldersKey as CFString,
                next.foldersData as CFData,
                applicationID
            )
            changed = true
        }
        if next.hiddenIDs != current.hiddenIDs.sorted() {
            CFPreferencesSetAppValue(
                LaunchpadPersistence.hiddenAppsKey as CFString,
                next.hiddenIDs as CFArray,
                applicationID
            )
            changed = true
        }
        if changed {
            CFPreferencesAppSynchronize(applicationID)
        }
        writeThroughIfCurrentDomain(domain, next)
    }

    public static func persistFolders(domain: String, _ folders: [AppFolder]) {
        guard let foldersData = try? encodeFolders(folders) else { return }
        var layout = readLayout(domain: domain)
        layout.foldersData = foldersData
        writeLayout(domain: domain, layout)
    }

    public static func persistItemOrder(domain: String, _ order: [String]) {
        var layout = readLayout(domain: domain)
        layout.itemOrder = order
        writeLayout(domain: domain, layout)
    }

    public static func persistHiddenApps(domain: String, _ hidden: Set<String>) {
        var layout = readLayout(domain: domain)
        layout.hiddenIDs = hidden.sorted()
        writeLayout(domain: domain, layout)
    }

    public static func readString(domain: String, key: String) -> String? {
        let applicationID = domain as CFString
        CFPreferencesAppSynchronize(applicationID)
        guard let value = CFPreferencesCopyAppValue(key as CFString, applicationID) else {
            return nil
        }
        return value as? String
    }

    public static func readStringArray(domain: String, key: String) -> [String] {
        let applicationID = domain as CFString
        CFPreferencesAppSynchronize(applicationID)
        return copyStringArray(key: key, applicationID: applicationID)
    }

    public static func writeThroughToStandardDefaults(_ layout: LaunchpadPersistedLayout) {
        let hidden = layout.hiddenIDs.sorted()
        UserDefaults.standard.set(layout.itemOrder, forKey: LaunchpadPersistence.itemOrderKey)
        UserDefaults.standard.set(layout.foldersData, forKey: LaunchpadPersistence.foldersKey)
        UserDefaults.standard.set(hidden, forKey: LaunchpadPersistence.hiddenAppsKey)
    }

    public static func layoutBackupFileURL(domain: String) -> URL {
        let folderName = domain == developmentDomain ? "QLaunch Dev" : "QLaunch"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("layout.backup.json")
    }

    public static func writeLayoutBackup(domain: String, document: LaunchpadLayoutDocument) throws {
        let data = try LaunchpadLayoutDocument.makeEncoder(pretty: true).encode(document)
        let url = layoutBackupFileURL(domain: domain)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func writeThroughIfCurrentDomain(_ domain: String, _ layout: LaunchpadPersistedLayout) {
        let currentDomain = Bundle.main.bundleIdentifier
            ?? (kCFPreferencesCurrentApplication as String)
        guard domain == currentDomain else { return }
        writeThroughToStandardDefaults(layout)
    }

    private static func copyStringArray(key: String, applicationID: CFString) -> [String] {
        guard let value = CFPreferencesCopyAppValue(key as CFString, applicationID) else {
            return []
        }
        if let strings = value as? [String] {
            return strings
        }
        if let array = value as? NSArray {
            return array.compactMap { $0 as? String }
        }
        return []
    }

    private static func copyData(key: String, applicationID: CFString) -> Data {
        guard let value = CFPreferencesCopyAppValue(key as CFString, applicationID) else {
            return Data()
        }
        if let data = value as? Data {
            return data
        }
        return Data()
    }
}
