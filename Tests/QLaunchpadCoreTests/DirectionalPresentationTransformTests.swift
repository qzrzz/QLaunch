import CoreGraphics
import XCTest
import QLaunchpadCore

final class DirectionalPresentationTransformTests: XCTestCase {
    func testOriginsMapToTheFourCornersInTopLeftCoordinates() {
        let size = CGSize(width: 1200, height: 800)
        let margin: CGFloat = 40
        XCTAssertEqual(LaunchpadPresentationCorner.topLeft.offscreenOrigin(in: size, margin: margin),
                       CGPoint(x: -40, y: -40))
        XCTAssertEqual(LaunchpadPresentationCorner.topRight.offscreenOrigin(in: size, margin: margin),
                       CGPoint(x: 1240, y: -40))
        XCTAssertEqual(LaunchpadPresentationCorner.bottomLeft.offscreenOrigin(in: size, margin: margin),
                       CGPoint(x: -40, y: 840))
        XCTAssertEqual(LaunchpadPresentationCorner.bottomRight.offscreenOrigin(in: size, margin: margin),
                       CGPoint(x: 1240, y: 840))
    }

    func testStaggerStartsNearestTheTriggerAndFansAcrossTheGrid() {
        for corner in LaunchpadPresentationCorner.allCases {
            let origin = corner.offscreenOrigin(in: CGSize(width: 1, height: 1), margin: 1)
            let column: CGFloat = origin.x < 0 ? 0 : 1
            let row: CGFloat = origin.y < 0 ? 0 : 1
            XCTAssertEqual(corner.staggerPhase(column: column, row: row), 0)
            XCTAssertEqual(corner.staggerPhase(column: 0.5, row: 0.5), 0.5)
            XCTAssertEqual(corner.staggerPhase(column: 1 - column, row: 1 - row), 1)
        }
    }

    func testLastIconStillFinishesAtItsExactRestPose() {
        let start = DirectionalPresentationTransform.sample(progress: 0, staggerPhase: 1, initialScale: 0.55)
        let near = DirectionalPresentationTransform.sample(progress: 0.3, staggerPhase: 0, initialScale: 0.55)
        let far = DirectionalPresentationTransform.sample(progress: 0.3, staggerPhase: 1, initialScale: 0.55)
        let end = DirectionalPresentationTransform.sample(progress: 1, staggerPhase: 1, initialScale: 0.55)
        XCTAssertEqual(start.opacity, 0)
        XCTAssertEqual(start.position, 0)
        XCTAssertLessThan(far.position, near.position)
        XCTAssertLessThan(far.opacity, near.opacity)
        XCTAssertEqual(end.position, 1)
        XCTAssertEqual(end.scale, 1)
        XCTAssertEqual(end.opacity, 1)
    }
}
