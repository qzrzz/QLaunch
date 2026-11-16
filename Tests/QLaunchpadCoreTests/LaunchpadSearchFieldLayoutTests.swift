import CoreGraphics
import XCTest
@testable import QLaunchpadCore

final class LaunchpadSearchFieldLayoutTests: XCTestCase {
    func testDefaultFieldIsLargerAndSitsLowerOnDisplaysWithoutANotch() {
        let layout = LaunchpadSearchFieldLayout()

        XCTAssertEqual(layout.size, CGSize(width: 420, height: 48))
        XCTAssertEqual(layout.fontSize, 18)
        XCTAssertEqual(layout.topInset, 46)
    }

    func testAllSizesClearTheCameraAndReserveSpaceForTheGrid() {
        let bounds = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let safeTop: CGFloat = 38

        for preset in LaunchpadSearchFieldSize.allCases {
            let layout = LaunchpadSearchFieldLayout(preset: preset, availableWidth: bounds.width, displaySafeTop: safeTop)
            let hitRect = layout.hitRect(in: bounds, flipped: true)

            XCTAssertEqual(layout.topInset, safeTop + 16)
            XCTAssertGreaterThan(hitRect.minY, safeTop)
            XCTAssertEqual(hitRect.midY, layout.topInset + layout.size.height / 2)
            XCTAssertLessThan(hitRect.maxY, layout.minimumGridTop)
        }
    }

    func testHitRectUsesTheSameCenterInEitherCoordinateSystem() {
        let bounds = CGRect(x: 10, y: 20, width: 1470, height: 956)
        let layout = LaunchpadSearchFieldLayout(preset: .large, displaySafeTop: 38)
        let flippedRect = layout.hitRect(in: bounds, flipped: true)
        let unflippedRect = layout.hitRect(in: bounds)

        XCTAssertEqual(flippedRect.midX, bounds.midX)
        XCTAssertEqual(unflippedRect.midX, bounds.midX)
        XCTAssertEqual(flippedRect.minY - bounds.minY, bounds.maxY - unflippedRect.maxY)
        XCTAssertEqual(flippedRect.size, unflippedRect.size)
    }

    func testLargeFieldAndItsHitAreaFitOnNarrowDisplays() {
        let layout = LaunchpadSearchFieldLayout(preset: .large, availableWidth: 400)

        XCTAssertEqual(layout.size.width, 368)
        XCTAssertEqual(layout.hitSize.width, 400)
        XCTAssertEqual(layout.fontSize, 20)
    }
}
