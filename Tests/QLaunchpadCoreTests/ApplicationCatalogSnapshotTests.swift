import XCTest
@testable import QLaunchpadCore

final class ApplicationCatalogSnapshotTests: XCTestCase {
    func testNestedInstallAndRemovalInvalidateRecordedDirectory() throws {
        let root = try temporaryDirectory()
        let nested = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let app = nested.appendingPathComponent("Example.app")

        var beforeInstall = ApplicationCatalogSnapshot()
        beforeInstall.record(root.path)
        beforeInstall.record(nested.path)
        XCTAssertTrue(beforeInstall.matchesDisk())

        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        XCTAssertFalse(beforeInstall.matchesDisk())

        var afterInstall = ApplicationCatalogSnapshot()
        afterInstall.record(nested.path)
        XCTAssertTrue(afterInstall.matchesDisk())
        try FileManager.default.removeItem(at: app)
        XCTAssertFalse(afterInstall.matchesDisk())
    }

    func testMissingSourceBecomesAvailable() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Applications")
        var snapshot = ApplicationCatalogSnapshot()
        snapshot.record(source.path)
        XCTAssertTrue(snapshot.matchesDisk())

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        XCTAssertFalse(snapshot.matchesDisk())
    }

    func testChangesToSymbolicLinkTargetInvalidateRecordedLink() throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("Example.app")
        let link = root.appendingPathComponent("Link.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var snapshot = ApplicationCatalogSnapshot()
        snapshot.record(link.path)
        XCTAssertTrue(snapshot.matchesDisk())

        try FileManager.default.removeItem(at: target)
        XCTAssertFalse(snapshot.matchesDisk())
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
}
