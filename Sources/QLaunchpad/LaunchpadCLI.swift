import Darwin
import Foundation
import QLaunchpadCore

enum LaunchpadCLI {
    static func isInvocation(_ args: [String]) -> Bool {
        LaunchpadCLIInvocation.isInvocation(args)
    }

    static func run(_ args: [String]) -> Int32 {
        do {
            return try execute(args)
        } catch let error as CLIError {
            fputs("error: \(error.message)\n", stderr)
            if case .usage = error {
                fputs(usageText, stderr)
            }
            return error.exitCode
        } catch let error as LaunchpadLayoutError {
            fputs("error: \(describe(error))\n", stderr)
            return 2
        } catch let error as LaunchpadCLIInvocation.ParseError {
            fputs("error: \(error.message)\n", stderr)
            fputs(usageText, stderr)
            return 1
        } catch let error as DecodingError {
            fputs("error: invalid layout JSON: \(error)\n", stderr)
            return 2
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 3
        }
    }

    private static func execute(_ rawArgs: [String]) throws -> Int32 {
        let (command, options) = try LaunchpadCLIInvocation.parse(rawArgs)
        if options.help {
            fputs(usageText, stdout)
            return 0
        }

        switch command {
        case "export":
            return try runExport(options)
        case "import":
            return try runImport(options)
        case "validate":
            return try runValidate(options)
        default:
            throw CLIError.usage("unknown command '\(command)'")
        }
    }

    private static func runExport(_ options: LaunchpadCLIInvocation.Options) throws -> Int32 {
        let domain = try resolveDomain(options)
        fputs("usingDomain: \(domain)\n", stderr)
        try ensureDomainAvailable(domain)

        let snapshot = try scanAndReconcile(domain: domain, failOnCorruptFolders: false)
        let document = makeDocument(
            snapshot,
            grid: gridSnapshot(domain: domain),
            includeCatalog: options.includeCatalog,
            includePaths: options.includePaths,
            appVersion: appVersion(options)
        )
        let pretty = try LaunchpadCLIInvocation.shouldPretty(
            pretty: options.pretty,
            compact: options.compact,
            writingToStdout: isStandardStream(options.out),
            stdoutIsTTY: isatty(STDOUT_FILENO) != 0
        )
        let data = try LaunchpadLayoutDocument.makeEncoder(pretty: pretty).encode(document)
        try writeOutput(data, to: options.out)
        return 0
    }

    private static func runImport(_ options: LaunchpadCLIInvocation.Options) throws -> Int32 {
        if options.merge && options.replace {
            throw CLIError.usage("--merge and --replace are mutually exclusive")
        }
        let domain = try resolveDomain(options)
        fputs("usingDomain: \(domain)\n", stderr)
        try ensureDomainAvailable(domain)

        let data = try readInput(options.input)
        try LaunchpadLayoutImporter.validateJSONSize(data)
        let document = try LaunchpadLayoutDocument.makeDecoder().decode(
            LaunchpadLayoutDocument.self,
            from: data
        )
        try LaunchpadLayoutImporter.validate(document)

        let snapshot = try scanAndReconcile(domain: domain, failOnCorruptFolders: true)
        if snapshot.apps.isEmpty {
            throw CLIError.validate("application catalog is empty")
        }

        let mode: LaunchpadLayoutImportMode = options.replace ? .replace : .merge
        let (applied, report) = try LaunchpadLayoutImporter.apply(
            document: document,
            mode: mode,
            strict: options.strict,
            scanned: snapshot.apps,
            currentHidden: snapshot.hidden
        )

        if options.dryRun {
            printReport(report, wouldWriteDomain: domain)
            return 0
        }

        writeBackupFailOpen(domain: domain, snapshot: snapshot, appVersion: appVersion(options))
        let foldersData = try LaunchpadPreferenceStore.encodeFolders(applied.folders)
        let wrote = LaunchpadPreferenceStore.writeLayout(
            domain: domain,
            LaunchpadPersistedLayout(
                itemOrder: applied.order,
                foldersData: foldersData,
                hiddenIDs: Array(applied.hidden)
            )
        )
        guard wrote else {
            throw CLIError.prefsUnavailable("failed to persist layout to \(domain)")
        }
        DistributedNotificationCenter.default().postNotificationName(
            .qlaunchpadLayoutDidChange,
            object: domain,
            userInfo: ["source": "cli", "schemaVersion": 1],
            deliverImmediately: true
        )
        printReport(report, wouldWriteDomain: nil)
        return 0
    }

    private static func runValidate(_ options: LaunchpadCLIInvocation.Options) throws -> Int32 {
        let data = try readInput(options.input)
        try LaunchpadLayoutImporter.validateJSONSize(data)
        let document = try LaunchpadLayoutDocument.makeDecoder().decode(
            LaunchpadLayoutDocument.self,
            from: data
        )
        try LaunchpadLayoutImporter.validate(document)
        return 0
    }

    // MARK: - Domain

    private static func resolveDomain(_ options: LaunchpadCLIInvocation.Options) throws -> String {
        let appIdentifier: String?
        if options.domain == nil, let appPath = options.app {
            appIdentifier = try bundleIdentifier(fromAppPath: appPath)
        } else {
            appIdentifier = nil
        }
        return try LaunchpadCLIInvocation.resolveDomain(
            explicitDomain: options.domain,
            appIdentifier: appIdentifier,
            dev: options.dev,
            bundledIdentifier: Bundle.main.bundleIdentifier
        )
    }

    private static func bundleIdentifier(fromAppPath path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw CLIError.io("app bundle not found: \(path)")
        }
        let url = appBundleURL(from: URL(fileURLWithPath: expanded))
        guard let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.prefsUnavailable("could not read CFBundleIdentifier from \(url.path)")
        }
        return identifier
    }

    private static func appBundleURL(from url: URL) -> URL {
        if url.pathExtension == "app" {
            return url
        }
        var current = url
        for _ in 0..<6 {
            if current.pathExtension == "app" {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return url
    }

    private static func ensureDomainAvailable(_ domain: String) throws {
        if !CFPreferencesAppSynchronize(domain as CFString) {
            throw CLIError.prefsUnavailable("preference domain unavailable: \(domain)")
        }
    }

    // MARK: - Scan / document

    private struct Snapshot {
        var apps: [LaunchpadKnownApp]
        var folders: [AppFolder]
        var order: [String]
        var hidden: Set<String>
    }

    private static func scanAndReconcile(domain: String, failOnCorruptFolders: Bool) throws -> Snapshot {
        let extraRoots = LaunchpadPreferenceStore.readStringArray(
            domain: domain,
            key: LaunchpadPersistence.customSourcesKey
        ).map { URL(fileURLWithPath: $0) }
        let known = AppScanner.scan(additionalRoots: extraRoots).map { app in
            LaunchpadKnownApp(
                id: app.id,
                bundleIdentifier: app.bundleIdentifier,
                name: app.name,
                path: app.url.standardizedFileURL.path
            )
        }
        let persisted = LaunchpadPreferenceStore.readLayout(domain: domain)
        let folders: [AppFolder]
        do {
            folders = try LaunchpadPreferenceStore.decodePersistedFolders(persisted.foldersData)
        } catch {
            if failOnCorruptFolders {
                throw CLIError.validate("corrupt launchpadFolders data: \(error.localizedDescription)")
            }
            fputs(
                "warning: corrupt launchpadFolders data; exporting without folders: \(error.localizedDescription)\n",
                stderr
            )
            folders = []
        }
        let hidden = Set(persisted.hiddenIDs)
        let reconciled = LaunchpadLayoutReconciler.reconcile(
            apps: known,
            folders: folders,
            order: persisted.itemOrder,
            hidden: hidden
        )
        return Snapshot(
            apps: known,
            folders: reconciled.folders,
            order: reconciled.order,
            hidden: hidden
        )
    }

    private static func gridSnapshot(domain: String) -> LaunchpadLayoutGrid {
        let raw = LaunchpadPreferenceStore.readString(
            domain: domain,
            key: LaunchpadPersistence.gridLayoutPresetKey
        )
        let preset: GridLayoutPreset
        if let rawValue = raw, let parsed = GridLayoutPreset(rawValue: rawValue) {
            preset = parsed
        } else {
            preset = .defaultPreset
        }
        return LaunchpadLayoutGrid(
            preset: preset.rawValue,
            columns: preset.columns,
            rows: preset.rows,
            pageCapacity: preset.columns * preset.rows
        )
    }

    private static func makeDocument(
        _ snapshot: Snapshot,
        grid: LaunchpadLayoutGrid,
        includeCatalog: Bool,
        includePaths: Bool,
        appVersion: String?
    ) -> LaunchpadLayoutDocument {
        let folderByID = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
        var seen = Set<String>()
        var items: [LaunchpadLayoutItem] = []
        for id in snapshot.order {
            guard seen.insert(id).inserted else { continue }
            if let folder = folderByID[id] {
                items.append(.folder(id: folder.id, name: folder.name, apps: folder.appIDs))
            } else if snapshot.apps.contains(where: { $0.id == id }) {
                items.append(.app(id: id))
            }
        }
        for folder in snapshot.folders where seen.insert(folder.id).inserted {
            items.append(.folder(id: folder.id, name: folder.name, apps: folder.appIDs))
        }
        let catalog: [LaunchpadLayoutCatalogEntry]? = includeCatalog
            ? snapshot.apps.map { app in
                LaunchpadLayoutCatalogEntry(
                    id: app.id,
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.name,
                    path: includePaths ? app.path : nil
                )
            }
            : nil
        return LaunchpadLayoutDocument(
            exportedAt: Date(),
            appVersion: appVersion,
            grid: grid,
            items: items,
            hidden: snapshot.hidden.sorted(),
            catalog: catalog
        )
    }

    private static func appVersion(_ options: LaunchpadCLIInvocation.Options) -> String? {
        if let appPath = options.app {
            let url = appBundleURL(from: URL(fileURLWithPath: (appPath as NSString).expandingTildeInPath))
            if let bundle = Bundle(url: url),
               let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                return version
            }
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private static func writeBackupFailOpen(domain: String, snapshot: Snapshot, appVersion: String?) {
        let document = makeDocument(
            snapshot,
            grid: gridSnapshot(domain: domain),
            includeCatalog: true,
            includePaths: true,
            appVersion: appVersion
        )
        do {
            try LaunchpadPreferenceStore.writeLayoutBackup(domain: domain, document: document)
        } catch {
            fputs("warning: failed to write layout backup: \(error.localizedDescription)\n", stderr)
        }
    }

    // MARK: - I/O

    private static func readInput(_ path: String?) throws -> Data {
        if let path, path != "-" {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                return try Data(contentsOf: url)
            } catch {
                throw CLIError.io("failed to read \(path): \(error.localizedDescription)")
            }
        }
        do {
            return try FileHandle.standardInput.readToEnd() ?? Data()
        } catch {
            throw CLIError.io("failed to read stdin: \(error.localizedDescription)")
        }
    }

    private static func writeOutput(_ data: Data, to path: String?) throws {
        var payload = data
        if payload.last != UInt8(ascii: "\n") {
            payload.append(UInt8(ascii: "\n"))
        }
        if let path, path != "-" {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try payload.write(to: url, options: .atomic)
            } catch {
                throw CLIError.io("failed to write \(path): \(error.localizedDescription)")
            }
            return
        }
        FileHandle.standardOutput.write(payload)
    }

    private static func isStandardStream(_ path: String?) -> Bool {
        path == nil || path == "-"
    }

    private static func printReport(_ report: LaunchpadLayoutReport, wouldWriteDomain: String?) {
        let rootApps = max(0, report.importedRootItems - report.importedFolders)
        let referenced = report.resolvedApps + report.skippedUnknown.count
        fputs(
            """
            imported: \(report.importedRootItems) items (\(report.importedFolders) folders, \(rootApps) root apps)
            resolved: \(report.resolvedApps) / \(referenced) referenced ids
            skippedUnknown: \(formatList(report.skippedUnknown))
            appendedLeftover: \(formatList(report.appendedLeftover))
            hiddenReplaced: \(report.hiddenReplaced)
            unhiddenByClaim: \(formatList(report.unhiddenByClaim))
            newlyHiddenByReplace: \(formatList(report.newlyHiddenByReplace))

            """,
            stdout
        )
        if let wouldWriteDomain {
            fputs("wouldWriteDomain: \(wouldWriteDomain)\n", stdout)
        }
    }

    private static func formatList(_ ids: [String]) -> String {
        ids.isEmpty ? "(none)" : ids.joined(separator: ", ")
    }

    private static func describe(_ error: LaunchpadLayoutError) -> String {
        switch error {
        case .invalidKind(let kind):
            return "invalid kind: \(kind)"
        case .unsupportedSchemaVersion(let version):
            return "unsupported schemaVersion: \(version)"
        case .malformed(let reason):
            return "malformed: \(reason)"
        case .limitExceeded(let limit):
            return "limit exceeded: \(limit)"
        case .duplicateID(let id):
            return "duplicate id: \(id)"
        case .nestedFolder(let id):
            return "nested folder: \(id)"
        case .itemHiddenOverlap(let id):
            return "item overlaps hidden: \(id)"
        case .strictUnresolved(let ids):
            return "strict: unresolved ids: \(ids.joined(separator: ", "))"
        }
    }

    private static let usageText = """
    QLaunchpad export   [--out <path>|-] [--pretty|--compact]
                        [--no-catalog] [--no-paths]
                        [--domain <bundle-id>] [--dev]
                        [--app <QLaunch.app>]

    QLaunchpad import   [--in <path>|-] [--merge|--replace] [--strict] [--dry-run]
                        [--domain <bundle-id>] [--dev]
                        [--app <QLaunch.app>]

    QLaunchpad validate [--in <path>|-]
    QLaunchpad help

    """

    private enum CLIError: Error {
        case usage(String)
        case validate(String)
        case io(String)
        case prefsUnavailable(String)

        var message: String {
            switch self {
            case .usage(let text), .validate(let text), .io(let text), .prefsUnavailable(let text):
                return text
            }
        }

        var exitCode: Int32 {
            switch self {
            case .usage: 1
            case .validate: 2
            case .io: 3
            case .prefsUnavailable: 4
            }
        }
    }
}
