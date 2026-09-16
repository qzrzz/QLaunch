import XCTest
import QLaunchpadCore

final class LaunchpadPageSnapTests: XCTestCase {
    func testMouseWheelUsesTheDominantAxisAndFlipsDirection() {
        XCTAssertEqual(
            LaunchpadPageSnap.mouseWheelPageDelta(deltaX: 0, deltaY: -1),
            1
        )
        XCTAssertEqual(
            LaunchpadPageSnap.mouseWheelPageDelta(deltaX: 4, deltaY: 1),
            -1
        )
    }

    func testMouseWheelIgnoresEmptyDelta() {
        XCTAssertNil(LaunchpadPageSnap.mouseWheelPageDelta(deltaX: 0, deltaY: 0))
        XCTAssertNil(LaunchpadPageSnap.mouseWheelPageDelta(deltaX: 0.005, deltaY: 0))
    }

    func testPreciseWheelWithoutPhasesUsesDiscretePaging() {
        XCTAssertTrue(
            LaunchpadPageSnap.isDiscreteWheel(
                isPrecise: true,
                phaseIsEmpty: true,
                momentumPhaseIsEmpty: true
            )
        )
        XCTAssertFalse(
            LaunchpadPageSnap.isDiscreteWheel(
                isPrecise: true,
                phaseIsEmpty: false,
                momentumPhaseIsEmpty: true
            )
        )
        XCTAssertTrue(
            LaunchpadPageSnap.isDiscreteWheel(
                isPrecise: false,
                phaseIsEmpty: false,
                momentumPhaseIsEmpty: false
            )
        )
    }

    func testDiscreteWheelCooldownUsesAcceptedEventTime() {
        XCTAssertTrue(
            LaunchpadPageSnap.acceptsDiscreteWheel(
                now: 0,
                lastAcceptedAt: -.infinity,
                cooldown: 0.8
            )
        )
        XCTAssertFalse(
            LaunchpadPageSnap.acceptsDiscreteWheel(
                now: 0.7,
                lastAcceptedAt: 0,
                cooldown: 0.8
            )
        )
        XCTAssertTrue(
            LaunchpadPageSnap.acceptsDiscreteWheel(
                now: 0.8,
                lastAcceptedAt: 0,
                cooldown: 0.8
            )
        )
    }

    func testMouseCommitIsLowerThanHalfPage() {
        XCTAssertLessThan(LaunchpadPageSnap.mouseCommitThreshold, 0.5)
        XCTAssertLessThan(
            LaunchpadPageSnap.mouseCommitThreshold,
            LaunchpadPageSnap.trackpadCommitThreshold
        )
        XCTAssertLessThan(
            LaunchpadPageSnap.mouseFlickThreshold,
            LaunchpadPageSnap.trackpadFlickThreshold
        )
    }

    func testMousePanCommitsAfterShortDrag() {
        let page = LaunchpadPageSnap.settledPage(
            offset: 0.18,
            origin: 0,
            velocity: 0,
            pageCount: 4,
            flickThreshold: LaunchpadPageSnap.mouseFlickThreshold,
            commitThreshold: LaunchpadPageSnap.mouseCommitThreshold
        )
        XCTAssertEqual(page, 1)
    }

    func testMousePanSnapsBackBelowCommitThreshold() {
        let page = LaunchpadPageSnap.settledPage(
            offset: 0.10,
            origin: 0,
            velocity: 0,
            pageCount: 4,
            flickThreshold: LaunchpadPageSnap.mouseFlickThreshold,
            commitThreshold: LaunchpadPageSnap.mouseCommitThreshold
        )
        XCTAssertEqual(page, 0)
    }

    func testMousePanFlicksToNextPage() {
        let page = LaunchpadPageSnap.settledPage(
            offset: 0.06,
            origin: 0,
            velocity: 0.5,
            pageCount: 4,
            flickThreshold: LaunchpadPageSnap.mouseFlickThreshold,
            commitThreshold: LaunchpadPageSnap.mouseCommitThreshold
        )
        XCTAssertEqual(page, 1)
    }

    func testMousePanDoesNotLeaveTheCatalog() {
        let page = LaunchpadPageSnap.settledPage(
            offset: 2.4,
            origin: 2,
            velocity: 1,
            pageCount: 3,
            flickThreshold: LaunchpadPageSnap.mouseFlickThreshold,
            commitThreshold: LaunchpadPageSnap.mouseCommitThreshold
        )
        XCTAssertEqual(page, 2)
    }

    func testMousePanCanCrossMoreThanOnePage() {
        let page = LaunchpadPageSnap.settledPage(
            offset: 1.6,
            origin: 0,
            velocity: 0,
            pageCount: 4,
            flickThreshold: LaunchpadPageSnap.mouseFlickThreshold,
            commitThreshold: LaunchpadPageSnap.mouseCommitThreshold
        )
        XCTAssertEqual(page, 2)
    }
}
