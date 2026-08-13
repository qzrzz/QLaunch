import CoreFoundation
import XCTest
@testable import QLaunchpadCore

final class LaunchpadPreferenceStoreTests: XCTestCase {
    private let domain = "com.qzrzz.qlaunchpad.tests.preference-store"

    override func tearDown() {
        clearLayoutDomain(domain)
        super.tearDown()
    }

    func testWriteLayoutStoresCFArrayAndCFDataAndSortsHidden() throws {
        let folders = [
            AppFolder(
                id: "folder-550e8400-e29b-41d4-a716-446655440000",
                name: "开发",
                appIDs: ["com.apple.dt.Xcode", "com.microsoft.VSCode"]
            )
        ]
        let foldersData = try LaunchpadPreferenceStore.encodeFolders(folders)
        LaunchpadPreferenceStore.writeLayout(
            domain: domain,
            LaunchpadPersistedLayout(
                itemOrder: ["folder-550e8400-e29b-41d4-a716-446655440000", "com.apple.Safari"],
                foldersData: foldersData,
                hiddenIDs: ["com.zebra", "com.alpha"]
            )
        )

        let read = LaunchpadPreferenceStore.readLayout(domain: domain)
        XCTAssertEqual(
            read.itemOrder,
            ["folder-550e8400-e29b-41d4-a716-446655440000", "com.apple.Safari"]
        )
        XCTAssertEqual(read.foldersData, foldersData)
        XCTAssertEqual(read.hiddenIDs, ["com.alpha", "com.zebra"])
        XCTAssertEqual(try LaunchpadPreferenceStore.decodeFolders(read.foldersData), folders)

        CFPreferencesAppSynchronize(domain as CFString)
        let rawFolders = CFPreferencesCopyAppValue(
            LaunchpadPersistence.foldersKey as CFString,
            domain as CFString
        )
        XCTAssertTrue(rawFolders is Data)
        XCTAssertFalse(rawFolders is String)

        let rawOrder = CFPreferencesCopyAppValue(
            LaunchpadPersistence.itemOrderKey as CFString,
            domain as CFString
        )
        XCTAssertEqual(rawOrder as? [String], read.itemOrder)
    }

    func testPersistIfChangedSkipsSecondWrite() throws {
        let folders = [AppFolder(id: "folder-a", name: "A", appIDs: ["com.alpha"])]
        let foldersData = try LaunchpadPreferenceStore.encodeFolders(folders)
        let layout = LaunchpadPersistedLayout(
            itemOrder: ["folder-a"],
            foldersData: foldersData,
            hiddenIDs: ["com.hidden"]
        )
        LaunchpadPreferenceStore.writeLayout(domain: domain, layout)

        let probeKey = "layoutWriteProbe"
        CFPreferencesSetAppValue(probeKey as CFString, "keep" as CFString, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)

        let plistURL = preferencesPlistURL(domain)
        let firstModified = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: plistURL.path)[.modificationDate] as? Date
        )

        LaunchpadPreferenceStore.writeLayout(domain: domain, layout)

        let secondModified = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: plistURL.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(firstModified, secondModified)
        XCTAssertEqual(
            CFPreferencesCopyAppValue(probeKey as CFString, domain as CFString) as? String,
            "keep"
        )

        let read = LaunchpadPreferenceStore.readLayout(domain: domain)
        XCTAssertEqual(read.itemOrder, ["folder-a"])
        XCTAssertEqual(read.foldersData, foldersData)
        XCTAssertEqual(read.hiddenIDs, ["com.hidden"])
    }

    func testReadStringAndStringArray() {
        CFPreferencesSetAppValue(
            LaunchpadPersistence.gridLayoutPresetKey as CFString,
            "7x5-128" as CFString,
            domain as CFString
        )
        CFPreferencesSetAppValue(
            LaunchpadPersistence.customSourcesKey as CFString,
            ["/tmp/Extra Apps"] as CFArray,
            domain as CFString
        )
        CFPreferencesAppSynchronize(domain as CFString)

        XCTAssertEqual(
            LaunchpadPreferenceStore.readString(
                domain: domain,
                key: LaunchpadPersistence.gridLayoutPresetKey
            ),
            "7x5-128"
        )
        XCTAssertEqual(
            LaunchpadPreferenceStore.readStringArray(
                domain: domain,
                key: LaunchpadPersistence.customSourcesKey
            ),
            ["/tmp/Extra Apps"]
        )
    }

    func testMissingLayoutKeysAreEmpty() {
        let read = LaunchpadPreferenceStore.readLayout(domain: domain)
        XCTAssertEqual(read.itemOrder, [])
        XCTAssertEqual(read.foldersData, Data())
        XCTAssertEqual(read.hiddenIDs, [])
        XCTAssertNil(
            LaunchpadPreferenceStore.readString(
                domain: domain,
                key: LaunchpadPersistence.gridLayoutPresetKey
            )
        )
        XCTAssertEqual(
            LaunchpadPreferenceStore.readStringArray(
                domain: domain,
                key: LaunchpadPersistence.customSourcesKey
            ),
            []
        )
    }

    func testBackupURLSplitsReleaseAndDevDomains() {
        let release = LaunchpadPreferenceStore.layoutBackupFileURL(
            domain: LaunchpadPreferenceStore.releaseDomain
        )
        let development = LaunchpadPreferenceStore.layoutBackupFileURL(
            domain: LaunchpadPreferenceStore.developmentDomain
        )
        XCTAssertTrue(release.path.hasSuffix("Application Support/QLaunch/layout.backup.json"))
        XCTAssertTrue(development.path.hasSuffix("Application Support/QLaunch Dev/layout.backup.json"))
        XCTAssertNotEqual(release, development)
    }

    func testEncodeFoldersWrapperMatchesPersistenceEncoder() throws {
        let folders = [
            AppFolder(id: "folder-1", name: "开发", appIDs: ["com.example.Foo#/Users/alex/Applications/Foo.app"])
        ]
        XCTAssertEqual(
            try LaunchpadPreferenceStore.encodeFolders(folders),
            try LaunchpadPersistence.encodeFolders(folders)
        )
    }

    private func preferencesPlistURL(_ domain: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domain).plist")
    }

    private func clearLayoutDomain(_ domain: String) {
        let applicationID = domain as CFString
        CFPreferencesSetAppValue(LaunchpadPersistence.itemOrderKey as CFString, nil, applicationID)
        CFPreferencesSetAppValue(LaunchpadPersistence.foldersKey as CFString, nil, applicationID)
        CFPreferencesSetAppValue(LaunchpadPersistence.hiddenAppsKey as CFString, nil, applicationID)
        CFPreferencesSetAppValue(LaunchpadPersistence.gridLayoutPresetKey as CFString, nil, applicationID)
        CFPreferencesSetAppValue(LaunchpadPersistence.customSourcesKey as CFString, nil, applicationID)
        CFPreferencesSetAppValue("layoutWriteProbe" as CFString, nil, applicationID)
        CFPreferencesAppSynchronize(applicationID)
        try? FileManager.default.removeItem(at: preferencesPlistURL(domain))
    }
}
