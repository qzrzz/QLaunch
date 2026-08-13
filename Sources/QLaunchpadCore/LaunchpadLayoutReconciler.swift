import Foundation

public enum LaunchpadLayoutReconciler {
    /// Matches `AppStore.reconcileLaunchpadItems()`: drop empty folders, strip
    /// hidden members, keep the first copy of a duplicated app, append folders
    /// missing from `order` before leftover apps.
    public static func reconcile(
        apps: [LaunchpadKnownApp],
        folders: [AppFolder],
        order: [String],
        hidden: Set<String>
    ) -> (folders: [AppFolder], order: [String]) {
        let validApps = Set(apps.map(\.id)).subtracting(hidden)
        var usedAppIDs = Set<String>()
        var sanitizedFolders: [AppFolder] = []
        for folder in folders {
            let members = folder.appIDs.filter { validApps.contains($0) && usedAppIDs.insert($0).inserted }
            guard !members.isEmpty else { continue }
            var sanitized = folder
            sanitized.appIDs = members
            sanitizedFolders.append(sanitized)
        }

        let folderByID = Dictionary(uniqueKeysWithValues: sanitizedFolders.map { ($0.id, $0) })
        var validOrder: [String] = []
        var seen = Set<String>()
        for id in order {
            if let folder = folderByID[id], seen.insert(id).inserted {
                validOrder.append(folder.id)
            } else if validApps.contains(id), !usedAppIDs.contains(id), seen.insert(id).inserted {
                validOrder.append(id)
            }
        }
        for folder in sanitizedFolders where seen.insert(folder.id).inserted {
            validOrder.append(folder.id)
        }
        for app in apps where validApps.contains(app.id)
            && !usedAppIDs.contains(app.id)
            && seen.insert(app.id).inserted {
            validOrder.append(app.id)
        }
        return (sanitizedFolders, validOrder)
    }
}
