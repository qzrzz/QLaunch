import Foundation

/// A user-created group of applications. Folder membership is stored by the
/// stable identifier used by `AppInfo`, so rescanning applications does not
/// invalidate folders.
public struct AppFolder: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var appIDs: [String]

    public init(id: String = "folder-\(UUID().uuidString)", name: String = "文件夹", appIDs: [String]) {
        self.id = id
        self.name = name
        self.appIDs = appIDs
    }
}
