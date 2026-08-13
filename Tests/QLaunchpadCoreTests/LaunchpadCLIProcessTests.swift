import CoreFoundation
import XCTest
@testable import QLaunchpadCore

final class LaunchpadCLIProcessTests: XCTestCase {
    private let dryRunDomain = "com.qzrzz.qlaunchpad.tests.cli-dry-run"

    override func tearDown() {
        clearLayoutDomain(dryRunDomain)
        super.tearDown()
    }

    func testNakedExportExitsUsage() throws {
        let result = try runCLI(["export"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("preference domain is required"))
    }

    func testMergeReplaceXORExitsUsage() throws {
        let result = try runCLI(["import", "--merge", "--replace", "--dev"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("--merge"))
    }

    func testPrettyCompactXORExitsUsage() throws {
        let result = try runCLI(["export", "--pretty", "--compact", "--dev"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("--pretty"))
    }

    func testValidateFixtureSucceeds() throws {
        let fixture = try XCTUnwrap(canonicalFixtureURL())
        let result = try runCLI(["validate", "--in", fixture.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    func testValidateBadJSONExitsTwo() throws {
        let result = try runCLI(["validate", "--in", "-"], stdin: #"{"kind":"nope"}"#)
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("invalid layout JSON") || result.stderr.contains("schemaVersion"))
    }

    func testMissingInputFileExitsThree() throws {
        let result = try runCLI(["validate", "--in", "/tmp/does-not-exist-qlayout.json"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.stderr.contains("failed to read"))
    }

    func testAppWithoutIdentifierExitsFour() throws {
        let result = try runCLI(["export", "--app", "/Applications"])
        XCTAssertEqual(result.exitCode, 4)
        XCTAssertTrue(result.stderr.contains("CFBundleIdentifier"))
    }

    func testDevPrintsUsingDomainBeforeSchemaFailure() throws {
        let result = try runCLI(
            ["import", "--dev", "--dry-run", "--in", "-"],
            stdin: #"{"kind":"nope"}"#
        )
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(
            result.stderr.contains("usingDomain: \(LaunchpadPreferenceStore.developmentDomain)"),
            result.stderr
        )
    }

    func testDryRunDoesNotChangeTargetDomain() throws {
        let foldersData = try LaunchpadPreferenceStore.encodeFolders([])
        let original = LaunchpadPersistedLayout(
            itemOrder: ["com.example.keep-me"],
            foldersData: foldersData,
            hiddenIDs: ["com.example.hidden"]
        )
        XCTAssertTrue(LaunchpadPreferenceStore.writeLayout(domain: dryRunDomain, original))

        let document = """
        {
          "kind": "qlaunchpad.layout",
          "schemaVersion": 1,
          "items": []
        }
        """
        let result = try runCLI(
            ["import", "--domain", dryRunDomain, "--dry-run", "--in", "-"],
            stdin: document
        )
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("wouldWriteDomain: \(dryRunDomain)"), result.stdout)

        let read = LaunchpadPreferenceStore.readLayout(domain: dryRunDomain)
        XCTAssertEqual(read.itemOrder, original.itemOrder)
        XCTAssertEqual(read.foldersData, original.foldersData)
        XCTAssertEqual(read.hiddenIDs, original.hiddenIDs)
    }

    private struct CLIResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private func runCLI(_ arguments: [String], stdin: String? = nil) throws -> CLIResult {
        let binary = try qlaunchpadBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CLIResult(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }

    private func qlaunchpadBinary() throws -> URL {
        let fileManager = FileManager.default
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("QLaunchpad")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fallbacks = [
            root.appendingPathComponent(".build/debug/QLaunchpad"),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/QLaunchpad")
        ]
        if let found = fallbacks.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        throw XCTSkip("QLaunchpad binary not found next to tests")
    }

    private func canonicalFixtureURL() -> URL? {
        Bundle.module.url(forResource: "canonical-layout", withExtension: "json")
    }

    private func clearLayoutDomain(_ domain: String) {
        let applicationID = domain as CFString
        CFPreferencesSetAppValue(LaunchpadPersistence.itemOrderKey as CFString, nil, applicationID)
        CFPreferencesSetAppValue(LaunchpadPersistence.foldersKey as CFString, nil, applicationID)
        CFPreferencesSetAppValue(LaunchpadPersistence.hiddenAppsKey as CFString, nil, applicationID)
        CFPreferencesAppSynchronize(applicationID)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domain).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}
