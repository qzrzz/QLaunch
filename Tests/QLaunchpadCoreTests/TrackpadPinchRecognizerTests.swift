import XCTest
@testable import QLaunchpadCore

final class TrackpadPinchRecognizerTests: XCTestCase {
    func testFourFingerSpreadCanFinishVisuallyBeforeReleaseAndReverse() throws {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(4, radius: 0.2), timestamp: 1, mode: .fourOrFive)
        let spread = try XCTUnwrap(motion(in: detector.update(
            touches: touches(4, radius: 0.34), timestamp: 1.1, mode: .fourOrFive
        )))
        XCTAssertEqual(spread.progress, 1)
        XCTAssertTrue(spread.shouldComplete)
        XCTAssertEqual(detector.update(
            touches: touches(4, radius: 0.34), timestamp: 2, mode: .fourOrFive
        ), [])
        let reversed = try XCTUnwrap(motion(in: detector.update(
            touches: touches(4, radius: 0.2), timestamp: 2.1, mode: .fourOrFive
        )))
        XCTAssertEqual(reversed.progress, 0)
        XCTAssertFalse(reversed.shouldComplete)
    }

    private func touches(
        _ count: Int, radius: Double, offset: Double = 0, firstID: Int = 0
    ) -> [TrackpadTouch] {
        (0..<count).map { index in
            let angle = Double(index) * 2 * .pi / Double(count)
            return TrackpadTouch(
                id: firstID + index,
                x: 0.5 + offset + cos(angle) * radius,
                y: 0.5 + sin(angle) * radius
            )
        }
    }

    private func motion(in events: [TrackpadPinchRecognizer.Event]) -> TrackpadPinchMotion? {
        for case let .changed(motion) in events { return motion }
        return nil
    }

    func testModesRequireTheirFingerCountsForBothDirections() {
        for mode in TrackpadGestureMode.allCases {
            for count in 2...5 {
                for (direction, start, end) in [
                    (TrackpadPinchDirection.inward, 0.3, 0.18),
                    (TrackpadPinchDirection.outward, 0.18, 0.3),
                ] {
                    var detector = TrackpadPinchRecognizer()
                    _ = detector.update(touches: touches(count, radius: start), timestamp: 1, mode: mode)
                    let events = detector.update(touches: touches(count, radius: end), timestamp: 1.15, mode: mode)
                    XCTAssertEqual(motion(in: events)?.direction, mode.accepts(count) ? direction : nil)
                }
            }
        }
    }

    func testSmallPinchPreviewsAndStaysAtSameProgressDuringLongHold() throws {
        var detector = TrackpadPinchRecognizer()
        XCTAssertEqual(detector.update(touches: touches(4, radius: 0.3), timestamp: 1, mode: .fourOrFive), [.began])
        let held = touches(4, radius: 0.255)
        let preview = try XCTUnwrap(motion(in: detector.update(touches: held, timestamp: 1.12, mode: .fourOrFive)))
        XCTAssertGreaterThan(preview.progress, 0)
        XCTAssertFalse(preview.shouldComplete)
        XCTAssertEqual(detector.update(touches: held, timestamp: 5, mode: .fourOrFive), [])
        XCTAssertEqual(detector.update(touches: [], timestamp: 6, mode: .fourOrFive), [.ended(preview)])
        XCTAssertEqual(detector.update(touches: [], timestamp: 6.1, mode: .fourOrFive), [])
    }

    func testCrossingThresholdDoesNotFinishBeforeFingersLift() throws {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(4, radius: 0.3), timestamp: 1, mode: .fourOrFive)
        let motionEvents = detector.update(touches: touches(4, radius: 0.19), timestamp: 1.1, mode: .fourOrFive)
        let preview = try XCTUnwrap(motion(in: motionEvents))
        XCTAssertEqual(motionEvents, [.changed(preview)])
        XCTAssertTrue(preview.shouldComplete)
        XCTAssertLessThan(preview.progress, 1)
        XCTAssertEqual(detector.update(touches: [], timestamp: 1.2, mode: .fourOrFive), [.ended(preview)])
    }

    func testSlowPinchReportsFineProgressChangesBelowOnePercent() throws {
        var detector = TrackpadPinchRecognizer()
        let mode = TrackpadGestureMode.fourOrFive
        _ = detector.update(touches: touches(4, radius: 0.3), timestamp: 1, mode: mode)
        let first = try XCTUnwrap(motion(in: detector.update(
            touches: touches(4, radius: 0.26), timestamp: 1.1, mode: mode
        )))
        let next = try XCTUnwrap(motion(in: detector.update(
            touches: touches(4, radius: 0.2595), timestamp: 1.12, mode: mode
        )))
        XCTAssertGreaterThan(next.progress, first.progress)
        XCTAssertLessThan(next.progress - first.progress, 0.01)
        XCTAssertEqual(next.shouldComplete, first.shouldComplete)
    }

    func testSmallReboundDoesNotPullThePreviewBack() throws {
        var detector = TrackpadPinchRecognizer()
        let mode = TrackpadGestureMode.fourOrFive
        _ = detector.update(touches: touches(4, radius: 0.35), timestamp: 1, mode: mode)
        let held = try XCTUnwrap(motion(in: detector.update(
            touches: touches(4, radius: 0.29), timestamp: 1.1, mode: mode
        )))
        XCTAssertEqual(detector.update(touches: touches(4, radius: 0.312), timestamp: 4, mode: mode), [])
        let reversal = try XCTUnwrap(motion(in: detector.update(
            touches: touches(4, radius: 0.34), timestamp: 4.1, mode: mode
        )))
        XCTAssertLessThan(reversal.progress, held.progress)
        XCTAssertFalse(reversal.shouldComplete)
    }

    func testModeratePinchCanCompleteBeforePreviewReachesItsEnd() throws {
        var detector = TrackpadPinchRecognizer()
        let mode = TrackpadGestureMode.fourOrFive
        _ = detector.update(touches: touches(4, radius: 0.34), timestamp: 1, mode: mode)
        let preview = try XCTUnwrap(motion(in: detector.update(
            touches: touches(4, radius: 0.28), timestamp: 1.1, mode: mode
        )))
        XCTAssertTrue(preview.shouldComplete)
        XCTAssertLessThan(preview.progress, 0.65)
        XCTAssertEqual(detector.update(touches: [], timestamp: 1.2, mode: mode), [.ended(preview)])
    }

    func testReversingOutsideTheDeadBandMatchesForwardMotionRate() throws {
        var detector = TrackpadPinchRecognizer()
        let mode = TrackpadGestureMode.fourOrFive
        _ = detector.update(touches: touches(4, radius: 0.35), timestamp: 1, mode: mode)
        func move(to radius: Double, at time: Double) throws -> Double {
            try XCTUnwrap(motion(in: detector.update(
                touches: touches(4, radius: radius), timestamp: time, mode: mode
            ))).progress
        }
        let beforeAdvance = try move(to: 0.27, at: 1.1)
        let advanced = try move(to: 0.26, at: 1.2)
        let beforeRetreat = try move(to: 0.29, at: 1.3)
        let retreated = try move(to: 0.30, at: 1.4)
        XCTAssertEqual(advanced - beforeAdvance, beforeRetreat - retreated, accuracy: 0.0001)
    }

    func testReversingAfterCrossingThresholdReturnsToPreviewAndCancelsOnLift() throws {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(4, radius: 0.3), timestamp: 1, mode: .fourOrFive)
        let advance = try XCTUnwrap(motion(in: detector.update(
            touches: touches(4, radius: 0.18), timestamp: 1.1, mode: .fourOrFive
        )))
        let reversal = try XCTUnwrap(motion(in: detector.update(
            touches: touches(4, radius: 0.29), timestamp: 1.2, mode: .fourOrFive
        )))
        XCTAssertTrue(advance.shouldComplete)
        XCTAssertEqual(reversal.direction, .inward)
        XCTAssertEqual(reversal.progress, 0)
        XCTAssertFalse(reversal.shouldComplete)
        XCTAssertEqual(detector.update(touches: [], timestamp: 1.3, mode: .fourOrFive), [.ended(reversal)])
    }

    func testSpreadKeepsItsProgressWhileFingersLiftInSuccession() throws {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(4, radius: 0.18), timestamp: 1, mode: .fourOrFive)
        let spread = try XCTUnwrap(motion(in: detector.update(
            touches: touches(4, radius: 0.27), timestamp: 1.1, mode: .fourOrFive
        )))
        XCTAssertEqual(spread.direction, .outward)
        XCTAssertTrue(spread.shouldComplete)
        XCTAssertEqual(detector.update(touches: touches(3, radius: 0.18), timestamp: 2, mode: .fourOrFive), [])
        XCTAssertEqual(detector.update(touches: touches(1, radius: 0.18), timestamp: 3, mode: .fourOrFive), [])
        XCTAssertEqual(detector.update(touches: [], timestamp: 3.1, mode: .fourOrFive), [.ended(spread)])
    }

    func testBaselineRebasesWhenAnotherFingerJoinsBeforeMotion() {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(4, radius: 0.3), timestamp: 1, mode: .fourOrFive)
        XCTAssertEqual(detector.update(touches: touches(5, radius: 0.18), timestamp: 1.15, mode: .fourOrFive), [])
        XCTAssertEqual(detector.update(touches: touches(5, radius: 0.171), timestamp: 1.3, mode: .fourOrFive), [])
    }

    func testThreeFingerModeDoesNotInheritFiveFingerGestureDuringLift() {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(5, radius: 0.3), timestamp: 1, mode: .three)
        _ = detector.update(touches: touches(3, radius: 0.3), timestamp: 1.05, mode: .three)
        XCTAssertEqual(detector.update(touches: touches(3, radius: 0.18), timestamp: 1.2, mode: .three), [])
    }

    func testSwipeAndSmallJitterDoNotStartAPreview() {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(3, radius: 0.2), timestamp: 1, mode: .three)
        XCTAssertEqual(detector.update(touches: touches(3, radius: 0.195, offset: 0.1), timestamp: 1.15, mode: .three), [])
        XCTAssertEqual(detector.update(touches: touches(3, radius: 0.16, offset: 0.25), timestamp: 1.2, mode: .three), [])
    }

    func testLostLiftCancelsPreviousPreviewBeforeNewContacts() {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(4, radius: 0.3), timestamp: 1, mode: .fourOrFive)
        _ = detector.update(touches: touches(4, radius: 0.18), timestamp: 1.15, mode: .fourOrFive)
        let next = touches(4, radius: 0.3, firstID: 10)
        XCTAssertEqual(detector.update(touches: next, timestamp: 2, mode: .fourOrFive), [.cancelled, .began])
    }

    func testInvalidContactsCannotStartAGesture() {
        var detector = TrackpadPinchRecognizer()
        let invalid = [TrackpadTouch(id: 1, x: .nan, y: 0), TrackpadTouch(id: 2, x: 0, y: 0), TrackpadTouch(id: 3, x: 0, y: 0)]
        XCTAssertEqual(detector.update(touches: invalid, timestamp: 1, mode: .three), [.began])
        XCTAssertEqual(detector.update(touches: touches(3, radius: 0.1), timestamp: 1.15, mode: .three), [])
        XCTAssertEqual(detector.update(touches: [], timestamp: 1.2, mode: .three), [.ended(nil)])
    }
}
