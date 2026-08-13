import XCTest
@testable import QLaunchpadCore

final class LaunchpadLayoutProfileStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qlaunch-layout-profiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func testMissingIndexSynthesizesDefault() {
        let index = LaunchpadLayoutProfileStore.loadIndex(in: directory)
        XCTAssertEqual(index, .default)
        XCTAssertEqual(index.activeID, LaunchpadLayoutProfileStore.defaultProfileID)
        XCTAssertEqual(index.profiles.map(\.name), ["默认"])
    }

    func testSaveAndLoadIndexRoundTrip() throws {
        let extra = LaunchpadLayoutProfile(id: UUID().uuidString, name: "工作")
        let saved = LaunchpadLayoutProfileIndex(
            activeID: extra.id,
            profiles: [LaunchpadLayoutProfileIndex.default.profiles[0], extra]
        )
        try LaunchpadLayoutProfileStore.saveIndex(saved, in: directory)

        let loaded = LaunchpadLayoutProfileStore.loadIndex(in: directory)
        XCTAssertEqual(loaded.activeID, extra.id)
        XCTAssertEqual(loaded.profiles.map(\.id), [LaunchpadLayoutProfileStore.defaultProfileID, extra.id])
        XCTAssertEqual(loaded.profiles.map(\.name), ["默认", "工作"])
    }

    func testNormalizedIndexPrependsDefaultAndFixesDanglingActive() {
        let extra = LaunchpadLayoutProfile(id: UUID().uuidString, name: "游戏")
        let normalized = LaunchpadLayoutProfileStore.normalized(
            LaunchpadLayoutProfileIndex(activeID: "missing", profiles: [extra])
        )
        XCTAssertEqual(normalized.activeID, LaunchpadLayoutProfileStore.defaultProfileID)
        XCTAssertEqual(normalized.profiles.map(\.id), [
            LaunchpadLayoutProfileStore.defaultProfileID,
            extra.id
        ])
    }

    func testCorruptIndexFallsBackToDefault() throws {
        try Data("not-json".utf8).write(to: LaunchpadLayoutProfileStore.indexURL(in: directory))
        XCTAssertEqual(LaunchpadLayoutProfileStore.loadIndex(in: directory), .default)
    }

    func testDocumentRoundTrip() throws {
        let profileID = UUID().uuidString
        let document = LaunchpadLayoutDocument(
            items: [.app(id: "com.example.Foo"), .folder(id: "folder-1", name: "开发", apps: ["com.apple.dt.Xcode"])],
            hidden: ["com.hidden"]
        )
        try LaunchpadLayoutProfileStore.writeDocument(document, in: directory, profileID: profileID)
        let loaded = try LaunchpadLayoutProfileStore.readDocument(in: directory, profileID: profileID)
        XCTAssertEqual(loaded.items, document.items)
        XCTAssertEqual(loaded.hidden, document.hidden)
    }

    func testMissingDocumentThrows() {
        XCTAssertThrowsError(
            try LaunchpadLayoutProfileStore.readDocument(
                in: directory,
                profileID: LaunchpadLayoutProfileStore.defaultProfileID
            )
        ) { error in
            XCTAssertEqual(
                error as? LaunchpadLayoutProfileError,
                .missingDocument(LaunchpadLayoutProfileStore.defaultProfileID)
            )
        }
    }

    func testInvalidProfileIDRejected() {
        XCTAssertThrowsError(
            try LaunchpadLayoutProfileStore.documentURL(in: directory, profileID: "../evil")
        ) { error in
            XCTAssertEqual(
                error as? LaunchpadLayoutProfileError,
                .invalidProfileID("../evil")
            )
        }
        XCTAssertFalse(LaunchpadLayoutProfileStore.isValidProfileID("default/../passwd"))
        XCTAssertTrue(LaunchpadLayoutProfileStore.isValidProfileID("default"))
        XCTAssertTrue(LaunchpadLayoutProfileStore.isValidProfileID(UUID().uuidString))
    }

    func testCannotDeleteDefaultDocument() {
        XCTAssertFalse(LaunchpadLayoutProfileStore.canDelete(LaunchpadLayoutProfileStore.defaultProfileID))
        XCTAssertThrowsError(
            try LaunchpadLayoutProfileStore.removeDocument(
                in: directory,
                profileID: LaunchpadLayoutProfileStore.defaultProfileID
            )
        ) { error in
            XCTAssertEqual(error as? LaunchpadLayoutProfileError, .defaultProfileProtected)
        }
    }

    func testRemoveNamedDocument() throws {
        let profileID = UUID().uuidString
        try LaunchpadLayoutProfileStore.writeDocument(
            LaunchpadLayoutDocument(items: [.app(id: "com.example.Foo")]),
            in: directory,
            profileID: profileID
        )
        try LaunchpadLayoutProfileStore.removeDocument(in: directory, profileID: profileID)
        XCTAssertThrowsError(
            try LaunchpadLayoutProfileStore.readDocument(in: directory, profileID: profileID)
        )
    }

    func testNormalizedNameAndSuggestedName() {
        XCTAssertNil(LaunchpadLayoutProfileStore.normalizedName("   "))
        XCTAssertEqual(LaunchpadLayoutProfileStore.normalizedName("  工作  "), "工作")
        XCTAssertEqual(
            LaunchpadLayoutProfileStore.suggestedNewName(existing: LaunchpadLayoutProfileIndex.default.profiles),
            "新布局"
        )
        XCTAssertEqual(
            LaunchpadLayoutProfileStore.suggestedNewName(
                existing: [
                    LaunchpadLayoutProfile(id: "default", name: "默认"),
                    LaunchpadLayoutProfile(id: UUID().uuidString, name: "新布局"),
                    LaunchpadLayoutProfile(id: UUID().uuidString, name: "新布局 2")
                ]
            ),
            "新布局 3"
        )

        let long = String(repeating: "啊", count: LaunchpadLayoutProfileStore.maxNameScalars + 5)
        let clipped = LaunchpadLayoutProfileStore.normalizedName(long)
        XCTAssertEqual(clipped?.unicodeScalars.count, LaunchpadLayoutProfileStore.maxNameScalars)
    }

    func testLayoutsDirectorySplitsReleaseAndDevDomains() {
        let release = LaunchpadLayoutProfileStore.layoutsDirectory(
            domain: LaunchpadPreferenceStore.releaseDomain
        )
        let development = LaunchpadLayoutProfileStore.layoutsDirectory(
            domain: LaunchpadPreferenceStore.developmentDomain
        )
        XCTAssertTrue(release.path.hasSuffix("Application Support/QLaunch/layouts"))
        XCTAssertTrue(development.path.hasSuffix("Application Support/QLaunch Dev/layouts"))
        XCTAssertNotEqual(release, development)
    }
}
