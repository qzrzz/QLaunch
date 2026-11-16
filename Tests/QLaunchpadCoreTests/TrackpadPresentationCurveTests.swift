import XCTest
@testable import QLaunchpadCore

final class TrackpadPresentationCurveTests: XCTestCase {
    func testBlurStartsGentlyAndEndsAtConfiguredStrength() {
        let blur = TrackpadPresentationCurve.blurProgress
        XCTAssertEqual(blur(0), 0)
        XCTAssertEqual(blur(1), 1)
        XCTAssertGreaterThan(blur(0.25), 0)
        XCTAssertLessThan(blur(0.5), 0.5)
        XCTAssertLessThan(blur(0.25) - blur(0), blur(1) - blur(0.75))
        XCTAssertEqual(blur(-1), 0)
        XCTAssertEqual(blur(2), 1)
    }

    func testFastPinchNeverSkipsAFlightSegment() {
        let next = TrackpadPresentationCurve.nextInwardProgress
        let frame = 1.0 / 60
        let afterFastPinch = next(0, 0.96, frame)
        XCTAssertGreaterThan(afterFastPinch, 0)
        XCTAssertLessThanOrEqual(afterFastPinch, 0.046)
        XCTAssertEqual(next(0, 0.96, 0.2), next(0, 0.96, 1.0 / 30), accuracy: 0.000001)
        XCTAssertEqual(next(0.96, 0, frame), 0.96 - afterFastPinch, accuracy: 0.000001)
    }

    func testSlowMotionContinuesOnEachFrameAndStopsAtHeldPosition() {
        for fps in [60.0, 120.0] {
            var displayed: CGFloat = 0.25
            for _ in 0..<Int(fps / 20) {
                let next = TrackpadPresentationCurve.nextInwardProgress(
                    from: displayed, toward: 0.257, elapsed: 1 / fps
                )
                XCTAssertGreaterThan(next, displayed)
                XCTAssertLessThan(next, 0.257)
                displayed = next
            }
            for _ in 0..<Int(fps / 4) {
                displayed = TrackpadPresentationCurve.nextInwardProgress(
                    from: displayed, toward: 0.257, elapsed: 1 / fps
                )
            }
            XCTAssertEqual(displayed, 0.257)
        }
    }
}
