import Foundation

public enum LaunchpadPersistence {
    public static let hiddenAppsKey = "hiddenAppIdentifiers"
    public static let customSourcesKey = "customApplicationSourcePaths"
    public static let showHiddenAppsKey = "showHiddenAppsInSearch"
    public static let foldersKey = "launchpadFolders"
    public static let itemOrderKey = "launchpadItemOrder"
    public static let gridLayoutPresetKey = "gridLayoutPreset"
    public static let layoutModeKey = "launchpadLayoutMode"
    public static let recentLaunchDatesKey = "recentAppLaunchDates"

    /// Compact `[{id,name,appIDs}]`. Key order is fixed so persist-if-changed
    /// can compare encoded `Data` without false dirty writes.
    public static func encodeFolders(_ folders: [AppFolder]) throws -> Data {
        let encoder = JSONEncoder()
        var json = Data([UInt8(ascii: "[")])
        for (index, folder) in folders.enumerated() {
            if index > 0 {
                json.append(UInt8(ascii: ","))
            }
            json.append(UInt8(ascii: "{"))
            json.append(contentsOf: "\"id\":".utf8)
            json.append(try encoder.encode(folder.id))
            json.append(contentsOf: ",\"name\":".utf8)
            json.append(try encoder.encode(folder.name))
            json.append(contentsOf: ",\"appIDs\":[".utf8)
            for (appIndex, appID) in folder.appIDs.enumerated() {
                if appIndex > 0 {
                    json.append(UInt8(ascii: ","))
                }
                json.append(try encoder.encode(appID))
            }
            json.append(contentsOf: "]}".utf8)
        }
        json.append(UInt8(ascii: "]"))
        return json
    }

    public static func decodeFolders(_ data: Data) throws -> [AppFolder] {
        try JSONDecoder().decode([AppFolder].self, from: data)
    }
}
