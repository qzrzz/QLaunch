import Foundation

public enum LaunchpadLayoutResolver {
    public static func resolve(
        rawID: String,
        scanned: [LaunchpadKnownApp],
        catalog: [LaunchpadLayoutCatalogEntry]?
    ) -> LaunchpadKnownApp? {
        if let exact = scanned.first(where: { $0.id == rawID }) {
            return exact
        }

        if let parsed = parseCompositeID(rawID) {
            let standardized = standardizedPath(parsed.path)
            if let match = scanned.first(where: {
                $0.bundleIdentifier == parsed.bundle
                    && standardizedPath($0.path) == standardized
            }) {
                return match
            }
        }

        if let catalog,
           let entry = catalog.first(where: { $0.id == rawID }),
           let path = entry.path {
            let standardized = standardizedPath(path)
            if let match = scanned.first(where: {
                $0.bundleIdentifier == entry.bundleIdentifier
                    && standardizedPath($0.path) == standardized
            }) {
                return match
            }
        }

        let bundle = parseCompositeID(rawID)?.bundle ?? rawID
        let copies = scanned.filter { $0.bundleIdentifier == bundle }
        if copies.count == 1 {
            return copies[0]
        }

        return nil
    }

    private static func parseCompositeID(_ rawID: String) -> (bundle: String, path: String)? {
        guard let hash = rawID.firstIndex(of: "#") else { return nil }
        let bundle = String(rawID[..<hash])
        let path = String(rawID[rawID.index(after: hash)...])
        guard !bundle.isEmpty, !path.isEmpty else { return nil }
        return (bundle, path)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
