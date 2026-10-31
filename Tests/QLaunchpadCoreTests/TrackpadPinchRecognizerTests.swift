import XCTest
@testable import QLaunchpadCore

final class TrackpadPinchRecognizerTests: XCTestCase {
    private func touches(_ count: Int, radius: Double, offset: Double = 0) -> [TrackpadTouch] {
        (0..<count).map { index in
            let angle = Double(index) * 2 * .pi / Double(count)
            return TrackpadTouch(id: index, x: 0.5 + offset + cos(angle) * radius, y: 0.5 + sin(angle) * radius)
        }
    }

    private func pinch(_ count: Int, mode: TrackpadGestureMode) -> Bool {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(count, radius: 0.3), timestamp: 1, mode: mode)
        return detector.update(touches: touches(count, radius: 0.18), timestamp: 1.15, mode: mode)
    }

    func testModesRequireTheirFingerCounts() {
        for count in 2...5 {
            XCTAssertEqual(pinch(count, mode: .three), count == 3)
            XCTAssertEqual(pinch(count, mode: .five), count == 5)
            XCTAssertEqual(pinch(count, mode: .fourOrFive), count >= 4)
            XCTAssertFalse(pinch(count, mode: .disabled))
        }
    }

    func testOnlyTriggersOnceUntilAllFingersLift() {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(4, radius: 0.3), timestamp: 1, mode: .fourOrFive)
        XCTAssertTrue(detector.update(touches: touches(4, radius: 0.18), timestamp: 1.15, mode: .fourOrFive))
        XCTAssertFalse(detector.update(touches: touches(4, radius: 0.12), timestamp: 1.2, mode: .fourOrFive))
        _ = detector.update(touches: [], timestamp: 1.22, mode: .fourOrFive)
        _ = detector.update(touches: touches(4, radius: 0.3), timestamp: 1.3, mode: .fourOrFive)
        XCTAssertTrue(detector.update(touches: touches(4, radius: 0.18), timestamp: 1.45, mode: .fourOrFive))
    }

    func testShowDesktopSpreadAndReboundDoNotTrigger() {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(4, radius: 0.2), timestamp: 1, mode: .fourOrFive)
        XCTAssertFalse(detector.update(touches: touches(4, radius: 0.3), timestamp: 1.15, mode: .fourOrFive))
        XCTAssertFalse(detector.update(touches: touches(4, radius: 0.1), timestamp: 1.3, mode: .fourOrFive))
    }

    func testSwipeAndSmallJitterDoNotTrigger() {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(3, radius: 0.2), timestamp: 1, mode: .three)
        XCTAssertFalse(detector.update(touches: touches(3, radius: 0.19, offset: 0.1), timestamp: 1.15, mode: .three))
        XCTAssertFalse(detector.update(touches: touches(3, radius: 0.2, offset: 0.2), timestamp: 1.2, mode: .three))
    }

    func testFiveFingerGestureDoesNotBecomeThreeFingerGestureDuringLift() {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(5, radius: 0.3), timestamp: 1, mode: .three)
        _ = detector.update(touches: touches(3, radius: 0.3), timestamp: 1.05, mode: .three)
        XCTAssertFalse(detector.update(touches: touches(3, radius: 0.18), timestamp: 1.2, mode: .three))
    }

    func testAddingFingerRebasesInsteadOfProducingFalseContraction() {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(4, radius: 0.3), timestamp: 1, mode: .fourOrFive)
        XCTAssertFalse(detector.update(touches: touches(5, radius: 0.18), timestamp: 1.15, mode: .fourOrFive))
        XCTAssertFalse(detector.update(touches: touches(5, radius: 0.17), timestamp: 1.3, mode: .fourOrFive))
    }

    func testLostFramesResetTheBaseline() {
        var detector = TrackpadPinchRecognizer()
        _ = detector.update(touches: touches(3, radius: 0.3), timestamp: 1, mode: .three)
        XCTAssertFalse(detector.update(touches: touches(3, radius: 0.18), timestamp: 2, mode: .three))
        XCTAssertTrue(detector.update(touches: touches(3, radius: 0.1), timestamp: 2.15, mode: .three))
    }

    func testInvalidContactsDoNotTrigger() {
        var detector = TrackpadPinchRecognizer()
        let invalid = [TrackpadTouch(id: 1, x: .nan, y: 0), TrackpadTouch(id: 2, x: 0, y: 0), TrackpadTouch(id: 3, x: 0, y: 0)]
        XCTAssertFalse(detector.update(touches: invalid, timestamp: 1, mode: .three))
        XCTAssertFalse(detector.update(touches: touches(3, radius: 0.1), timestamp: 1.15, mode: .three))
    }
}
