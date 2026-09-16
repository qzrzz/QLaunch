import XCTest
@testable import QLaunchpadCore

final class ClassicPresentationTransformTests: XCTestCase {
    func testEntranceDepthStartsNearAndSettlesAtIdentity() {
        XCTAssertEqual(
            ClassicPresentationTransform.scale(progress: 0, showing: true),
            1.12,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ClassicPresentationTransform.scale(progress: 1, showing: true),
            1,
            accuracy: 0.0001
        )
    }

    func testDismissalDepthMovesImmediatelyAndEndsNear() {
        let start = ClassicPresentationTransform.scale(progress: 1, showing: false)
        let firstFrame = ClassicPresentationTransform.scale(progress: 0.95, showing: false)

        XCTAssertEqual(start, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(firstFrame, start)
        XCTAssertEqual(
            ClassicPresentationTransform.scale(progress: 0, showing: false),
            1.12,
            accuracy: 0.0001
        )
    }
}
