import XCTest
@testable import QLaunchpadCore

final class LaunchpadLaunchReasonTests: XCTestCase {
    func testCommandLineFlagMarksLoginItemEvenWithoutAppleEvent() {
        let reason = LaunchpadLaunchReason.resolve(
            commandLineArguments: ["--launched-at-login"],
            appleEventID: nil,
            appleEventLaunchedAsLoginItem: false
        )
        XCTAssertEqual(reason, .loginItem)
        XCTAssertFalse(reason.shouldPresentLaunchpad)
    }

    func testOpenApplicationLoginItemAppleEventHidesLaunchpad() {
        let reason = LaunchpadLaunchReason.resolve(
            commandLineArguments: [],
            appleEventID: LaunchpadLaunchReason.openApplicationEventID,
            appleEventLaunchedAsLoginItem: true
        )
        XCTAssertEqual(reason, .loginItem)
        XCTAssertFalse(reason.shouldPresentLaunchpad)
    }

    func testLoginItemFlagWithoutEventIDStillHidesLaunchpad() {
        let reason = LaunchpadLaunchReason.resolve(
            commandLineArguments: [],
            appleEventID: nil,
            appleEventLaunchedAsLoginItem: true
        )
        XCTAssertEqual(reason, .loginItem)
    }

    func testMissingAppleEventIsUserLaunchAndPresents() {
        let reason = LaunchpadLaunchReason.resolve(
            commandLineArguments: [],
            appleEventID: nil,
            appleEventLaunchedAsLoginItem: false
        )
        XCTAssertEqual(reason, .user)
        XCTAssertTrue(reason.shouldPresentLaunchpad)
    }

    func testOpenApplicationWithoutLoginFlagIsUserLaunch() {
        let reason = LaunchpadLaunchReason.resolve(
            commandLineArguments: ["--dev"],
            appleEventID: LaunchpadLaunchReason.openApplicationEventID,
            appleEventLaunchedAsLoginItem: false
        )
        XCTAssertEqual(reason, .user)
        XCTAssertTrue(reason.shouldPresentLaunchpad)
    }

    func testNonOpenEventDoesNotCountAsLoginItem() {
        let openDocuments: UInt32 = 0x6F64_6F63 // 'odoc'
        let reason = LaunchpadLaunchReason.resolve(
            commandLineArguments: [],
            appleEventID: openDocuments,
            appleEventLaunchedAsLoginItem: true
        )
        XCTAssertEqual(reason, .user)
    }

    func testEnabledLoginItemJustAfterBootIsLoginLaunch() {
        let reason = LaunchpadLaunchReason.resolve(
            commandLineArguments: [],
            appleEventID: LaunchpadLaunchReason.openApplicationEventID,
            appleEventLaunchedAsLoginItem: false,
            loginItemEnabled: true,
            systemUptime: 12
        )
        XCTAssertEqual(reason, .loginItem)
        XCTAssertFalse(reason.shouldPresentLaunchpad)
    }

    func testEnabledLoginItemAfterBootWindowIsUserLaunch() {
        let reason = LaunchpadLaunchReason.resolve(
            commandLineArguments: [],
            appleEventID: nil,
            appleEventLaunchedAsLoginItem: false,
            loginItemEnabled: true,
            systemUptime: LaunchpadLaunchReason.loginItemBootWindow + 1
        )
        XCTAssertEqual(reason, .user)
        XCTAssertTrue(reason.shouldPresentLaunchpad)
    }

    func testBootWindowDoesNotApplyWhenLoginItemDisabled() {
        let reason = LaunchpadLaunchReason.resolve(
            commandLineArguments: [],
            appleEventID: nil,
            appleEventLaunchedAsLoginItem: false,
            loginItemEnabled: false,
            systemUptime: 5
        )
        XCTAssertEqual(reason, .user)
    }
}
