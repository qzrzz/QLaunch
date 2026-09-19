import XCTest
@testable import QLaunchpadCore

final class MacOSLaunchpadReaderTests: XCTestCase {
    func testNonExistentDatabaseThrowsNotFound() {
        let fakeURL = URL(fileURLWithPath: "/tmp/non_existent_launchpad_db_\(UUID().uuidString).db")
        XCTAssertThrowsError(try MacOSLaunchpadReader.readLayoutDocument(from: fakeURL)) { error in
            XCTAssertEqual(error as? MacOSLaunchpadError, .databaseNotFound)
        }
    }

    func testSystemDatabaseIfAvailableParsesValidDocument() throws {
        guard let dbURL = MacOSLaunchpadReader.defaultDatabaseURL() else {
            // If running in an environment without macOS Launchpad DB, skip gracefully
            return
        }

        let document = try MacOSLaunchpadReader.readLayoutDocument(from: dbURL)
        XCTAssertEqual(document.kind, LaunchpadLayoutKind.current)
        XCTAssertEqual(document.schemaVersion, LaunchpadLayoutKind.schemaVersion)
        XCTAssertFalse(document.items.isEmpty)
        XCTAssertNoThrow(try LaunchpadLayoutImporter.validate(document))
    }
}
