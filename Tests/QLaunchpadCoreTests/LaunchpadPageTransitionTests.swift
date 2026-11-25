import QLaunchpadCore
import XCTest

final class LaunchpadPageTransitionTests: XCTestCase {
    func testFramesAt60And120HzFollowTheSameTimelineWithSmallerStepsAt120Hz() {
        let transition = LaunchpadPageTransition(from: 4, to: 5, start: 0)
        let frames60 = (0...20).map { transition.position(at: Double($0) / 60) }
        let frames120 = (0...40).map { transition.position(at: Double($0) / 120) }

        XCTAssertEqual(frames60, stride(from: 0, through: 40, by: 2).map { frames120[$0] })
        XCTAssertLessThan(frames60[1] - 4, 0.01)
        XCTAssertEqual(frames60.last, 5)
        XCTAssertLessThan(maximumStep(in: frames60), 0.08)
        XCTAssertLessThan(maximumStep(in: frames120), 0.04)
    }

    func testGestureSettlementCarriesVelocityAndArrivesWithoutOvershooting() {
        let transition = LaunchpadPageTransition(
            from: 4.6, to: 4, start: 0, incomingVelocity: -2
        )
        let dt = 0.0001
        XCTAssertEqual((transition.position(at: dt) - 4.6) / dt, -2, accuracy: 0.01)
        let frames = (0...30).map { transition.position(at: Double($0) / 120) }
        XCTAssertEqual(frames, frames.sorted(by: >))
        XCTAssertEqual(transition.position(at: transition.duration), 4)
    }

    private func maximumStep(in frames: [Double]) -> Double {
        zip(frames, frames.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }
}
