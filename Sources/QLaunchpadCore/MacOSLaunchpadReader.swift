import Darwin
import Foundation
import SQLite3

public enum MacOSLaunchpadError: LocalizedError, Equatable {
    case databaseNotFound
    case cannotOpenDatabase(Int32)
    case queryFailed(String)
    case emptyDatabase

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            return "未找到 macOS 原生启动台数据库文件"
        case .cannotOpenDatabase(let code):
            return "无法打开 macOS 启动台数据库 (SQLite 错误码 \(code))"
        case .queryFailed(let message):
            return "查询 macOS 启动台数据库失败: \(message)"
        case .emptyDatabase:
            return "macOS 启动台数据库未包含有效应用排列"
        }
    }
}

public enum MacOSLaunchpadReader {
    public static func defaultDatabaseURL() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
        guard len > 0 else { return nil }
        let userDir = buffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) }
        } ?? ""
        guard !userDir.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: userDir)
            .appendingPathComponent("com.apple.dock.launchpad/db/db")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    public static func readLayoutDocument(
        from databaseURL: URL? = nil
    ) throws -> LaunchpadLayoutDocument {
        guard let dbURL = databaseURL ?? defaultDatabaseURL(),
              FileManager.default.fileExists(atPath: dbURL.path) else {
            throw MacOSLaunchpadError.databaseNotFound
        }

        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let db else {
            if let db {
                sqlite3_close(db)
            }
            throw MacOSLaunchpadError.cannotOpenDatabase(openStatus)
        }
        defer { sqlite3_close(db) }

        let rootPageID = queryRootPageID(db)
        let pageIDs = queryChildPages(db, parentID: rootPageID)
        guard !pageIDs.isEmpty else {
            throw MacOSLaunchpadError.emptyDatabase
        }

        var items: [LaunchpadLayoutItem] = []
        var catalog: [String: LaunchpadLayoutCatalogEntry] = [:]
        var seenAppIDs = Set<String>()

        for pageID in pageIDs {
            let pageItems = queryPageItems(db, pageID: pageID)
            for item in pageItems {
                switch item {
                case .app(let title, let bundleID, let bookmark):
                    guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !bundleID.isEmpty else { continue }
                    guard seenAppIDs.insert(bundleID).inserted else { continue }
                    items.append(.app(id: bundleID))
                    let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedPath = bookmark.flatMap(resolveBookmarkPath)
                    catalog[bundleID] = LaunchpadLayoutCatalogEntry(
                        id: bundleID,
                        bundleIdentifier: bundleID,
                        name: (name?.isEmpty ?? true) ? bundleID : name!,
                        path: resolvedPath
                    )

                case .folder(let folderRowID, let folderTitle):
                    let trimmedTitle = folderTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let folderName = trimmedTitle.isEmpty ? "文件夹" : trimmedTitle
                    let folderPageIDs = queryChildPages(db, parentID: folderRowID)
                    var folderAppIDs: [String] = []

                    for folderPageID in folderPageIDs {
                        let folderApps = queryFolderPageApps(db, pageID: folderPageID)
                        for (appTitle, appBundleID, appBookmark) in folderApps {
                            guard let appBundleID = appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
                                  !appBundleID.isEmpty else { continue }
                            guard seenAppIDs.insert(appBundleID).inserted else { continue }
                            folderAppIDs.append(appBundleID)
                            let name = appTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let resolvedPath = appBookmark.flatMap(resolveBookmarkPath)
                            catalog[appBundleID] = LaunchpadLayoutCatalogEntry(
                                id: appBundleID,
                                bundleIdentifier: appBundleID,
                                name: (name?.isEmpty ?? true) ? appBundleID : name!,
                                path: resolvedPath
                            )
                        }
                    }

                    if !folderAppIDs.isEmpty {
                        items.append(
                            .folder(
                                id: "folder-\(folderRowID)",
                                name: folderName,
                                apps: folderAppIDs
                            )
                        )
                    }
                }
            }
        }

        guard !items.isEmpty else {
            throw MacOSLaunchpadError.emptyDatabase
        }

        let document = LaunchpadLayoutDocument(
            kind: LaunchpadLayoutKind.current,
            schemaVersion: LaunchpadLayoutKind.schemaVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            grid: nil,
            items: items,
            hidden: nil,
            catalog: catalog.values.sorted(by: { $0.id < $1.id })
        )
        try LaunchpadLayoutImporter.validate(document)
        return document
    }

    private enum RawPageItem {
        case app(title: String?, bundleID: String?, bookmark: Data?)
        case folder(folderRowID: Int64, title: String?)
    }

    private static func queryRootPageID(_ db: OpaquePointer) -> Int64 {
        let sql = "SELECT rowid FROM items WHERE uuid = 'ROOTPAGE' LIMIT 1"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return sqlite3_column_int64(stmt, 0)
            }
        }
        return 1
    }

    private static func queryChildPages(_ db: OpaquePointer, parentID: Int64) -> [Int64] {
        let sql = "SELECT rowid FROM items WHERE parent_id = ? AND (uuid IS NULL OR uuid != 'HOLDINGPAGE') ORDER BY ordering ASC"
        var stmt: OpaquePointer?
        var pages: [Int64] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, parentID)
            while sqlite3_step(stmt) == SQLITE_ROW {
                pages.append(sqlite3_column_int64(stmt, 0))
            }
        }
        return pages
    }

    private static func queryPageItems(_ db: OpaquePointer, pageID: Int64) -> [RawPageItem] {
        let sql = """
        SELECT i.rowid, i.type, a.title, a.bundleid, a.bookmark, g.title
        FROM items i
        LEFT JOIN apps a ON i.rowid = a.item_id
        LEFT JOIN groups g ON i.rowid = g.item_id
        WHERE i.parent_id = ?
        ORDER BY i.ordering ASC
        """
        var stmt: OpaquePointer?
        var results: [RawPageItem] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, pageID)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowID = sqlite3_column_int64(stmt, 0)
                let itemType = sqlite3_column_int(stmt, 1)
                let appTitle = columnString(stmt, index: 2)
                let appBundleID = columnString(stmt, index: 3)
                let appBookmark = columnData(stmt, index: 4)
                let groupTitle = columnString(stmt, index: 5)

                if itemType == 4 { // App
                    results.append(.app(title: appTitle, bundleID: appBundleID, bookmark: appBookmark))
                } else if itemType == 2 { // Folder / Group
                    results.append(.folder(folderRowID: rowID, title: groupTitle))
                }
            }
        }
        return results
    }

    private static func queryFolderPageApps(
        _ db: OpaquePointer,
        pageID: Int64
    ) -> [(title: String?, bundleID: String?, bookmark: Data?)] {
        let sql = """
        SELECT a.title, a.bundleid, a.bookmark
        FROM items i
        JOIN apps a ON i.rowid = a.item_id
        WHERE i.parent_id = ?
        ORDER BY i.ordering ASC
        """
        var stmt: OpaquePointer?
        var results: [(title: String?, bundleID: String?, bookmark: Data?)] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, pageID)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let appTitle = columnString(stmt, index: 0)
                let appBundleID = columnString(stmt, index: 1)
                let appBookmark = columnData(stmt, index: 2)
                results.append((title: appTitle, bundleID: appBundleID, bookmark: appBookmark))
            }
        }
        return results
    }

    private static func columnString(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: text)
    }

    private static func columnData(_ stmt: OpaquePointer, index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = sqlite3_column_bytes(stmt, index)
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: Int(count))
    }

    private static func resolveBookmarkPath(_ bookmarkData: Data) -> String? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return url.standardizedFileURL.path
    }
}
