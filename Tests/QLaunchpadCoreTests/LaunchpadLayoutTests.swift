import XCTest
@testable import QLaunchpadCore

final class LaunchpadLayoutTests: XCTestCase {
    func testEmptyFolderDropped() {
        let apps = known(
            ("com.alpha", "Alpha", "/A/Alpha.app"),
            ("com.bravo", "Bravo", "/A/Bravo.app")
        )
        let folders = [
            AppFolder(id: "folder-empty", name: "Empty", appIDs: []),
            AppFolder(id: "folder-keep", name: "Keep", appIDs: ["com.alpha"])
        ]
        let result = LaunchpadLayoutReconciler.reconcile(
            apps: apps,
            folders: folders,
            order: ["folder-empty", "com.bravo", "folder-keep"],
            hidden: []
        )
        XCTAssertEqual(result.folders.map(\.id), ["folder-keep"])
        XCTAssertEqual(result.order, ["com.bravo", "folder-keep"])
    }

    func testHiddenMembersStrippedFromFolderAndOrder() {
        let apps = known(
            ("com.alpha", "Alpha", "/A/Alpha.app"),
            ("com.bravo", "Bravo", "/A/Bravo.app"),
            ("com.charlie", "Charlie", "/A/Charlie.app")
        )
        let folders = [
            AppFolder(id: "folder-dev", name: "Dev", appIDs: ["com.alpha", "com.bravo"])
        ]
        let result = LaunchpadLayoutReconciler.reconcile(
            apps: apps,
            folders: folders,
            order: ["folder-dev", "com.charlie", "com.bravo"],
            hidden: ["com.bravo"]
        )
        XCTAssertEqual(result.folders.map(\.appIDs), [["com.alpha"]])
        XCTAssertEqual(result.order, ["folder-dev", "com.charlie"])
        XCTAssertFalse(result.order.contains("com.bravo"))
    }

    func testDuplicateAppKeepsFirstFolder() {
        let apps = known(
            ("com.alpha", "Alpha", "/A/Alpha.app"),
            ("com.bravo", "Bravo", "/A/Bravo.app")
        )
        let folders = [
            AppFolder(id: "folder-a", name: "A", appIDs: ["com.alpha"]),
            AppFolder(id: "folder-b", name: "B", appIDs: ["com.alpha", "com.bravo"])
        ]
        let result = LaunchpadLayoutReconciler.reconcile(
            apps: apps,
            folders: folders,
            order: ["folder-a", "folder-b"],
            hidden: []
        )
        XCTAssertEqual(result.folders.map(\.id), ["folder-a", "folder-b"])
        XCTAssertEqual(result.folders[0].appIDs, ["com.alpha"])
        XCTAssertEqual(result.folders[1].appIDs, ["com.bravo"])
    }

    func testLeftoverAppendOrderAndMissingFolderBeforeLeftoverApps() {
        let apps = known(
            ("com.zebra", "Zebra", "/Z/Zebra.app"),
            ("com.apple.b", "Apple", "/B/Apple.app"),
            ("com.apple.a", "Apple", "/A/Apple.app"),
            ("com.kept", "Kept", "/K/Kept.app")
        )
        let folders = [
            AppFolder(id: "folder-late", name: "Late", appIDs: ["com.kept"])
        ]
        let result = LaunchpadLayoutReconciler.reconcile(
            apps: apps,
            folders: folders,
            order: ["com.zebra"],
            hidden: []
        )
        XCTAssertEqual(
            result.order,
            ["com.zebra", "folder-late", "com.apple.a", "com.apple.b"]
        )
    }

    func testItemsHiddenOverlapRejected() {
        let document = LaunchpadLayoutDocument(
            items: [
                .app(id: "com.apple.Safari"),
                .folder(id: "folder-dev", name: "开发", apps: ["com.apple.dt.Xcode"])
            ],
            hidden: ["com.apple.Safari"]
        )
        XCTAssertThrowsError(
            try LaunchpadLayoutImporter.apply(
                document: document,
                mode: .merge,
                strict: false,
                scanned: known(("com.apple.Safari", "Safari", "/S/Safari.app")),
                currentHidden: []
            )
        ) { error in
            XCTAssertEqual(error as? LaunchpadLayoutError, .itemHiddenOverlap("com.apple.Safari"))
        }

        let folderOverlap = LaunchpadLayoutDocument(
            items: [
                .folder(id: "folder-dev", name: "开发", apps: ["com.apple.dt.Xcode"])
            ],
            hidden: ["com.apple.dt.Xcode"]
        )
        XCTAssertThrowsError(
            try LaunchpadLayoutImporter.apply(
                document: folderOverlap,
                mode: .merge,
                strict: false,
                scanned: known(("com.apple.dt.Xcode", "Xcode", "/X/Xcode.app")),
                currentHidden: []
            )
        ) { error in
            XCTAssertEqual(error as? LaunchpadLayoutError, .itemHiddenOverlap("com.apple.dt.Xcode"))
        }
    }

    func testCompositeIDResolvesWhenOnlyBareCopyRemains() throws {
        let scanned = known(
            ("com.example.Foo", "Foo", "/Users/alex/Applications/Foo.app")
        )
        let rawID = "com.example.Foo#/Users/alex/Applications/Foo.app"
        let resolved = LaunchpadLayoutResolver.resolve(rawID: rawID, scanned: scanned, catalog: nil)
        XCTAssertEqual(resolved?.id, "com.example.Foo")

        let document = LaunchpadLayoutDocument(items: [.app(id: rawID)])
        let result = try LaunchpadLayoutImporter.apply(
            document: document,
            mode: .merge,
            strict: true,
            scanned: scanned,
            currentHidden: []
        )
        XCTAssertEqual(result.layout.order, ["com.example.Foo"])
        XCTAssertEqual(result.report.resolvedApps, 1)
        XCTAssertTrue(result.report.skippedUnknown.isEmpty)
    }

    func testReplaceHidesLeftoversBeforeReconcile() throws {
        let scanned = known(
            ("com.kept", "Kept", "/K/Kept.app"),
            ("com.extra", "Extra", "/E/Extra.app")
        )
        let document = LaunchpadLayoutDocument(items: [.app(id: "com.kept")])
        let result = try LaunchpadLayoutImporter.apply(
            document: document,
            mode: .replace,
            strict: false,
            scanned: scanned,
            currentHidden: []
        )
        XCTAssertEqual(result.layout.order, ["com.kept"])
        XCTAssertTrue(result.layout.hidden.contains("com.extra"))
        XCTAssertFalse(result.layout.order.contains("com.extra"))
        XCTAssertEqual(result.report.newlyHiddenByReplace, ["com.extra"])
        XCTAssertTrue(result.report.appendedLeftover.isEmpty)
    }

    func testHiddenOmittedVersusPresentThreeState() throws {
        let scanned = known(
            ("com.alpha", "Alpha", "/A/Alpha.app"),
            ("com.bravo", "Bravo", "/B/Bravo.app"),
            ("com.hidden", "Hidden", "/H/Hidden.app")
        )
        let currentHidden: Set<String> = ["com.hidden"]

        let omitted = try LaunchpadLayoutImporter.apply(
            document: LaunchpadLayoutDocument(items: [.app(id: "com.alpha")]),
            mode: .merge,
            strict: false,
            scanned: scanned,
            currentHidden: currentHidden
        )
        XCTAssertEqual(omitted.layout.hidden, ["com.hidden"])
        XCTAssertFalse(omitted.report.hiddenReplaced)
        XCTAssertEqual(omitted.report.appendedLeftover, ["com.bravo"])
        XCTAssertTrue(omitted.layout.order.contains("com.bravo"))

        let replaced = try LaunchpadLayoutImporter.apply(
            document: LaunchpadLayoutDocument(
                items: [.app(id: "com.alpha")],
                hidden: ["com.bravo"]
            ),
            mode: .merge,
            strict: false,
            scanned: scanned,
            currentHidden: currentHidden
        )
        XCTAssertEqual(replaced.layout.hidden, ["com.bravo"])
        XCTAssertTrue(replaced.report.hiddenReplaced)
        XCTAssertTrue(replaced.layout.order.contains("com.hidden"))
        XCTAssertFalse(replaced.layout.order.contains("com.bravo"))

        let emptied = try LaunchpadLayoutImporter.apply(
            document: LaunchpadLayoutDocument(
                items: [.app(id: "com.alpha")],
                hidden: []
            ),
            mode: .merge,
            strict: false,
            scanned: scanned,
            currentHidden: currentHidden
        )
        XCTAssertTrue(emptied.layout.hidden.isEmpty)
        XCTAssertTrue(emptied.report.hiddenReplaced)
        XCTAssertEqual(Set(emptied.layout.order), ["com.alpha", "com.bravo", "com.hidden"])
    }

    func testOmittedHiddenUnhidesClaimedID() throws {
        let scanned = known(
            ("com.chess", "Chess", "/C/Chess.app"),
            ("com.preview", "Preview", "/P/Preview.app")
        )
        let result = try LaunchpadLayoutImporter.apply(
            document: LaunchpadLayoutDocument(items: [.app(id: "com.chess")]),
            mode: .merge,
            strict: false,
            scanned: scanned,
            currentHidden: ["com.chess"]
        )
        XCTAssertEqual(result.layout.order.first, "com.chess")
        XCTAssertEqual(result.report.unhiddenByClaim, ["com.chess"])
        XCTAssertFalse(result.layout.hidden.contains("com.chess"))
        XCTAssertTrue(result.report.appendedLeftover.contains("com.preview"))
    }

    func testCanonicalLayoutFixtureRoundTrip() throws {
        let fixture = try fixtureData("canonical-layout")
        let document = try LaunchpadLayoutDocument.makeDecoder()
            .decode(LaunchpadLayoutDocument.self, from: fixture)
        let encoded = try LaunchpadLayoutDocument.makeEncoder(pretty: true).encode(document)
        XCTAssertEqual(
            String(data: encoded, encoding: .utf8),
            String(data: fixture, encoding: .utf8)
        )

        XCTAssertEqual(document.kind, LaunchpadLayoutKind.current)
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.appVersion, "1.0.0")
        XCTAssertEqual(document.hidden, ["com.apple.Chess"])
        XCTAssertEqual(document.items, [
            .app(id: "com.apple.Safari"),
            .folder(
                id: "folder-550e8400-e29b-41d4-a716-446655440000",
                name: "开发",
                apps: ["com.apple.dt.Xcode", "com.microsoft.VSCode"]
            ),
            .app(id: "com.apple.Preview")
        ])
    }

    func testEncodeFoldersMatchesOnDiskFixtureAndDiffersFromLayoutEncoder() throws {
        let fixture = try fixtureData("persist-folders")
        let folders = try LaunchpadPersistence.decodeFolders(fixture)
        let reencoded = try LaunchpadPersistence.encodeFolders(folders)
        XCTAssertEqual(
            String(data: reencoded, encoding: .utf8),
            String(data: fixture, encoding: .utf8)
        )

        let layoutEncoded = try LaunchpadLayoutDocument.makeEncoder(pretty: true).encode(folders)
        XCTAssertNotEqual(layoutEncoded, reencoded)
        XCTAssertEqual(folders.map(\.id), ["folder-550e8400-e29b-41d4-a716-446655440000"])
        XCTAssertEqual(folders.first?.appIDs, ["com.apple.dt.Xcode", "com.microsoft.VSCode"])
    }

    func testDecodeFoldersAcceptsHistoricalJSONEncoderPayload() throws {
        let historical = Data(
            #"[{"id":"folder-550e8400-e29b-41d4-a716-446655440000","appIDs":["com.example.Foo#\/Users\/alex\/Applications\/Foo.app"],"name":"开发"}]"#.utf8
        )
        let folders = try LaunchpadPersistence.decodeFolders(historical)
        XCTAssertEqual(folders.map(\.id), ["folder-550e8400-e29b-41d4-a716-446655440000"])
        XCTAssertEqual(folders.first?.name, "开发")
        XCTAssertEqual(
            folders.first?.appIDs,
            ["com.example.Foo#/Users/alex/Applications/Foo.app"]
        )
    }

    func testTrimmedFolderIDsAreUnique() {
        let document = LaunchpadLayoutDocument(items: [
            .folder(id: "folder-a", name: "A", apps: ["com.alpha"]),
            .folder(id: " folder-a", name: "B", apps: ["com.bravo"])
        ])
        XCTAssertThrowsError(
            try LaunchpadLayoutImporter.apply(
                document: document,
                mode: .merge,
                strict: false,
                scanned: known(
                    ("com.alpha", "Alpha", "/A/Alpha.app"),
                    ("com.bravo", "Bravo", "/B/Bravo.app")
                ),
                currentHidden: []
            )
        ) { error in
            XCTAssertEqual(error as? LaunchpadLayoutError, .duplicateID("folder-a"))
        }
    }

    func testFolderIDCollidingWithLeftoverScannedAppRejected() {
        let document = LaunchpadLayoutDocument(items: [
            .folder(id: "folder-collide", name: "X", apps: ["com.alpha"])
        ])
        XCTAssertThrowsError(
            try LaunchpadLayoutImporter.apply(
                document: document,
                mode: .merge,
                strict: false,
                scanned: known(
                    ("com.alpha", "Alpha", "/A/Alpha.app"),
                    ("folder-collide", "Collide", "/C/Collide.app")
                ),
                currentHidden: []
            )
        ) { error in
            XCTAssertEqual(error as? LaunchpadLayoutError, .duplicateID("folder-collide"))
        }
    }

    func testResolvedIDAliasesRejectedAsDuplicate() {
        let scanned = known(
            ("com.example.Foo", "Foo", "/Users/alex/Applications/Foo.app")
        )
        let document = LaunchpadLayoutDocument(items: [
            .app(id: "com.example.Foo"),
            .app(id: "com.example.Foo#/Users/alex/Applications/Foo.app")
        ])
        XCTAssertThrowsError(
            try LaunchpadLayoutImporter.apply(
                document: document,
                mode: .merge,
                strict: false,
                scanned: scanned,
                currentHidden: []
            )
        ) { error in
            XCTAssertEqual(error as? LaunchpadLayoutError, .duplicateID("com.example.Foo"))
        }
    }

    private func known(_ items: (String, String, String)...) -> [LaunchpadKnownApp] {
        items
            .map { LaunchpadKnownApp(id: $0.0, bundleIdentifier: $0.0, name: $0.1, path: $0.2) }
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.path < rhs.path
            }
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
