import XCTest
@testable import QLaunchpadCore

final class LaunchpadCLIInvocationTests: XCTestCase {
    func testIsInvocationRequiresCommandOrCLIFlag() {
        XCTAssertFalse(LaunchpadCLIInvocation.isInvocation([]))
        XCTAssertFalse(LaunchpadCLIInvocation.isInvocation(["--out", "x.json"]))
        XCTAssertTrue(LaunchpadCLIInvocation.isInvocation(["export"]))
        XCTAssertTrue(LaunchpadCLIInvocation.isInvocation(["import"]))
        XCTAssertTrue(LaunchpadCLIInvocation.isInvocation(["validate"]))
        XCTAssertTrue(LaunchpadCLIInvocation.isInvocation(["help"]))
        XCTAssertTrue(LaunchpadCLIInvocation.isInvocation(["-h"]))
        XCTAssertTrue(LaunchpadCLIInvocation.isInvocation(["--help"]))
        XCTAssertTrue(LaunchpadCLIInvocation.isInvocation(["--cli"]))
        XCTAssertTrue(LaunchpadCLIInvocation.isInvocation(["--out", "x.json", "--cli"]))
    }

    func testParseMergeAndReplaceAreExclusive() {
        XCTAssertThrowsError(
            try LaunchpadCLIInvocation.parse(["import", "--merge", "--replace"])
        ) { error in
            guard case LaunchpadCLIInvocation.ParseError.usage(let message) = error else {
                return XCTFail("expected usage, got \(error)")
            }
            XCTAssertTrue(message.contains("--merge"))
        }
    }

    func testParsePrettyAndCompactAreExclusive() {
        XCTAssertThrowsError(
            try LaunchpadCLIInvocation.parse(["export", "--pretty", "--compact"])
        ) { error in
            guard case LaunchpadCLIInvocation.ParseError.usage(let message) = error else {
                return XCTFail("expected usage, got \(error)")
            }
            XCTAssertTrue(message.contains("--pretty"))
        }
    }

    func testParseDefaultsToMergeAndStripsCLIFlag() throws {
        let parsed = try LaunchpadCLIInvocation.parse(["--cli", "import", "--in", "-"])
        XCTAssertEqual(parsed.command, "import")
        XCTAssertEqual(parsed.options.input, "-")
        XCTAssertFalse(parsed.options.replace)
        XCTAssertFalse(parsed.options.merge)
    }

    func testShouldPrettyTTYVersusPipeAndFile() throws {
        XCTAssertTrue(
            try LaunchpadCLIInvocation.shouldPretty(
                pretty: false,
                compact: false,
                writingToStdout: true,
                stdoutIsTTY: true
            )
        )
        XCTAssertFalse(
            try LaunchpadCLIInvocation.shouldPretty(
                pretty: false,
                compact: false,
                writingToStdout: true,
                stdoutIsTTY: false
            )
        )
        XCTAssertTrue(
            try LaunchpadCLIInvocation.shouldPretty(
                pretty: false,
                compact: false,
                writingToStdout: false,
                stdoutIsTTY: false
            )
        )
        XCTAssertTrue(
            try LaunchpadCLIInvocation.shouldPretty(
                pretty: true,
                compact: false,
                writingToStdout: true,
                stdoutIsTTY: false
            )
        )
        XCTAssertFalse(
            try LaunchpadCLIInvocation.shouldPretty(
                pretty: false,
                compact: true,
                writingToStdout: true,
                stdoutIsTTY: true
            )
        )
        XCTAssertThrowsError(
            try LaunchpadCLIInvocation.shouldPretty(
                pretty: true,
                compact: true,
                writingToStdout: true,
                stdoutIsTTY: true
            )
        )
    }

    func testResolveDomainFailClosedAndPrecedence() throws {
        XCTAssertEqual(
            try LaunchpadCLIInvocation.resolveDomain(
                explicitDomain: "com.example.explicit",
                appIdentifier: "com.from.app",
                dev: true,
                bundledIdentifier: LaunchpadCLIInvocation.releaseDomain
            ),
            "com.example.explicit"
        )
        XCTAssertEqual(
            try LaunchpadCLIInvocation.resolveDomain(
                explicitDomain: nil,
                appIdentifier: "com.from.app",
                dev: true,
                bundledIdentifier: LaunchpadCLIInvocation.releaseDomain
            ),
            "com.from.app"
        )
        XCTAssertEqual(
            try LaunchpadCLIInvocation.resolveDomain(
                explicitDomain: nil,
                appIdentifier: nil,
                dev: true,
                bundledIdentifier: LaunchpadCLIInvocation.releaseDomain
            ),
            LaunchpadCLIInvocation.developmentDomain
        )
        XCTAssertEqual(
            try LaunchpadCLIInvocation.resolveDomain(
                explicitDomain: nil,
                appIdentifier: nil,
                dev: false,
                bundledIdentifier: LaunchpadCLIInvocation.releaseDomain
            ),
            LaunchpadCLIInvocation.releaseDomain
        )
        XCTAssertEqual(
            try LaunchpadCLIInvocation.resolveDomain(
                explicitDomain: nil,
                appIdentifier: nil,
                dev: false,
                bundledIdentifier: LaunchpadCLIInvocation.developmentDomain
            ),
            LaunchpadCLIInvocation.developmentDomain
        )
        XCTAssertThrowsError(
            try LaunchpadCLIInvocation.resolveDomain(
                explicitDomain: nil,
                appIdentifier: nil,
                dev: false,
                bundledIdentifier: nil
            )
        )
        XCTAssertThrowsError(
            try LaunchpadCLIInvocation.resolveDomain(
                explicitDomain: nil,
                appIdentifier: nil,
                dev: false,
                bundledIdentifier: "org.swift.swiftpm"
            )
        ) { error in
            guard case LaunchpadCLIInvocation.ParseError.usage = error else {
                return XCTFail("naked binary must not default to Release, got \(error)")
            }
        }
    }

    func testDecodePersistedFoldersEmptyVersusCorrupt() throws {
        XCTAssertEqual(try LaunchpadPreferenceStore.decodePersistedFolders(Data()), [])
        XCTAssertThrowsError(
            try LaunchpadPreferenceStore.decodePersistedFolders(Data("not-folders".utf8))
        )
        let encoded = try LaunchpadPreferenceStore.encodeFolders([
            AppFolder(id: "folder-a", name: "A", appIDs: ["com.alpha"])
        ])
        XCTAssertEqual(try LaunchpadPreferenceStore.decodePersistedFolders(encoded).count, 1)
    }
}
