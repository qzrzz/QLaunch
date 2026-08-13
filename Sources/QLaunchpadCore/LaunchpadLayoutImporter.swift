import Foundation

public enum LaunchpadLayoutImporter {
    public static let maxJSONBytes = 5 * 1024 * 1024
    public static let maxItems = 10_000
    public static let maxFolders = 2_000
    public static let maxFolderMembers = 500
    public static let maxNameScalars = 200
    public static let maxCatalogEntries = 10_000

    public static func apply(
        document: LaunchpadLayoutDocument,
        mode: LaunchpadLayoutImportMode,
        strict: Bool,
        scanned: [LaunchpadKnownApp],
        currentHidden: Set<String>
    ) throws -> (
        layout: (folders: [AppFolder], order: [String], hidden: Set<String>),
        report: LaunchpadLayoutReport
    ) {
        try validate(document)

        var resolvedByRawID: [String: LaunchpadKnownApp] = [:]
        var skippedUnknown: [String] = []
        var seenReferenced = Set<String>()
        for rawID in referencedIDs(in: document) {
            guard seenReferenced.insert(rawID).inserted else { continue }
            if let resolved = LaunchpadLayoutResolver.resolve(
                rawID: rawID,
                scanned: scanned,
                catalog: document.catalog
            ) {
                resolvedByRawID[rawID] = resolved
            } else {
                skippedUnknown.append(rawID)
            }
        }

        if strict {
            if !skippedUnknown.isEmpty {
                throw LaunchpadLayoutError.strictUnresolved(skippedUnknown)
            }
            for item in document.items {
                if case .folder(_, let name, _) = item,
                   name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw LaunchpadLayoutError.malformed("empty folder name")
                }
            }
        }

        var proposedFolders: [AppFolder] = []
        var proposedOrder: [String] = []
        for item in document.items {
            switch item {
            case .app(let rawID):
                guard let resolved = resolvedByRawID[rawID] else { continue }
                proposedOrder.append(resolved.id)
            case .folder(let rawID, let name, let apps):
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let folderName = trimmedName.isEmpty ? "文件夹" : trimmedName
                let folderID = normalizedFolderID(rawID)
                let members = apps.compactMap { resolvedByRawID[$0]?.id }
                proposedFolders.append(AppFolder(id: folderID, name: folderName, appIDs: members))
                proposedOrder.append(folderID)
            }
        }

        let resolvedAppIDs = Set(resolvedByRawID.values.map(\.id))
        for folder in proposedFolders where resolvedAppIDs.contains(folder.id) {
            throw LaunchpadLayoutError.duplicateID(folder.id)
        }

        var claimedIDs = Set<String>()
        for folder in proposedFolders {
            claimedIDs.formUnion(folder.appIDs)
        }
        let folderIDs = Set(proposedFolders.map(\.id))
        for id in proposedOrder where !folderIDs.contains(id) {
            claimedIDs.insert(id)
        }

        let hiddenReplaced = document.hidden != nil
        let hiddenBaseline: Set<String>
        let unhiddenByClaim: [String]
        if let hidden = document.hidden {
            hiddenBaseline = Set(hidden.compactMap { resolvedByRawID[$0]?.id })
            unhiddenByClaim = []
            for id in claimedIDs where hiddenBaseline.contains(id) {
                throw LaunchpadLayoutError.itemHiddenOverlap(id)
            }
        } else {
            hiddenBaseline = currentHidden.subtracting(claimedIDs)
            unhiddenByClaim = currentHidden.intersection(claimedIDs).sorted()
        }

        let leftoverIDs = scanned
            .filter { !claimedIDs.contains($0.id) && !hiddenBaseline.contains($0.id) }
            .sorted(by: Self.appSort)
            .map(\.id)

        let newlyHiddenByReplace: [String]
        let finalHidden: Set<String>
        if mode == .replace {
            newlyHiddenByReplace = leftoverIDs
            finalHidden = hiddenBaseline.union(leftoverIDs)
        } else {
            newlyHiddenByReplace = []
            finalHidden = hiddenBaseline
        }

        let reconciled = LaunchpadLayoutReconciler.reconcile(
            apps: scanned,
            folders: proposedFolders,
            order: proposedOrder,
            hidden: finalHidden
        )

        let leftoverInOrder = mode == .merge ? leftoverIDs : []
        let report = LaunchpadLayoutReport(
            importedRootItems: reconciled.order.count - leftoverInOrder.count,
            importedFolders: reconciled.folders.count,
            resolvedApps: resolvedByRawID.count,
            skippedUnknown: skippedUnknown,
            appendedLeftover: leftoverInOrder,
            hiddenReplaced: hiddenReplaced,
            unhiddenByClaim: unhiddenByClaim,
            newlyHiddenByReplace: newlyHiddenByReplace
        )
        return (
            layout: (folders: reconciled.folders, order: reconciled.order, hidden: finalHidden),
            report: report
        )
    }

    public static func validate(_ document: LaunchpadLayoutDocument) throws {
        if document.kind != LaunchpadLayoutKind.current {
            throw LaunchpadLayoutError.invalidKind(document.kind)
        }
        if document.schemaVersion != LaunchpadLayoutKind.schemaVersion {
            throw LaunchpadLayoutError.unsupportedSchemaVersion(document.schemaVersion)
        }
        if document.items.count > maxItems {
            throw LaunchpadLayoutError.limitExceeded("items")
        }
        let folderCount = document.items.reduce(0) { count, item in
            if case .folder = item { return count + 1 }
            return count
        }
        if folderCount > maxFolders {
            throw LaunchpadLayoutError.limitExceeded("folders")
        }
        if let catalog = document.catalog, catalog.count > maxCatalogEntries {
            throw LaunchpadLayoutError.limitExceeded("catalog")
        }

        var folderIDs = Set<String>()
        for item in document.items {
            if case .folder(let id, _, _) = item, let id {
                try rejectInvalidString(id)
                folderIDs.insert(id)
            }
        }

        var seenIDs = Set<String>()
        for item in document.items {
            switch item {
            case .app(let id):
                try rejectInvalidString(id)
                if !seenIDs.insert(id).inserted {
                    throw LaunchpadLayoutError.duplicateID(id)
                }
            case .folder(let id, let name, let apps):
                if name.unicodeScalars.contains("\0") {
                    throw LaunchpadLayoutError.malformed("string contains NUL")
                }
                if name.unicodeScalars.count > maxNameScalars {
                    throw LaunchpadLayoutError.limitExceeded("name")
                }
                if let id {
                    if !seenIDs.insert(id).inserted {
                        throw LaunchpadLayoutError.duplicateID(id)
                    }
                }
                if apps.count > maxFolderMembers {
                    throw LaunchpadLayoutError.limitExceeded("folder members")
                }
                for appID in apps {
                    try rejectInvalidString(appID)
                    if folderIDs.contains(appID) {
                        throw LaunchpadLayoutError.nestedFolder(appID)
                    }
                    if !seenIDs.insert(appID).inserted {
                        throw LaunchpadLayoutError.duplicateID(appID)
                    }
                }
            }
        }

        if let hidden = document.hidden {
            var seenHidden = Set<String>()
            for id in hidden {
                try rejectInvalidString(id)
                if !seenHidden.insert(id).inserted {
                    throw LaunchpadLayoutError.duplicateID(id)
                }
                if seenIDs.contains(id) {
                    throw LaunchpadLayoutError.itemHiddenOverlap(id)
                }
            }
        }

        if let catalog = document.catalog {
            for entry in catalog {
                try rejectInvalidString(entry.id)
                try rejectInvalidString(entry.bundleIdentifier)
                try rejectInvalidString(entry.name)
                if let path = entry.path {
                    try rejectInvalidString(path)
                }
            }
        }
    }

    public static func validateJSONSize(_ data: Data) throws {
        if data.count > maxJSONBytes {
            throw LaunchpadLayoutError.limitExceeded("json")
        }
    }

    private static func referencedIDs(in document: LaunchpadLayoutDocument) -> [String] {
        var ids: [String] = []
        for item in document.items {
            switch item {
            case .app(let id):
                ids.append(id)
            case .folder(_, _, let apps):
                ids.append(contentsOf: apps)
            }
        }
        if let hidden = document.hidden {
            ids.append(contentsOf: hidden)
        }
        return ids
    }

    private static func normalizedFolderID(_ rawID: String?) -> String {
        guard let rawID else {
            return "folder-\(UUID().uuidString)"
        }
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "folder-\(UUID().uuidString)" : trimmed
    }

    private static func rejectInvalidString(_ value: String) throws {
        if value.unicodeScalars.contains("\0") {
            throw LaunchpadLayoutError.malformed("string contains NUL")
        }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LaunchpadLayoutError.malformed("empty string")
        }
    }

    private static func appSort(_ lhs: LaunchpadKnownApp, _ rhs: LaunchpadKnownApp) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.path < rhs.path
    }
}
