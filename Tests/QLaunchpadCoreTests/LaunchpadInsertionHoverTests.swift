import CoreGraphics
import XCTest
import QLaunchpadCore

final class LaunchpadInsertionHoverTests: XCTestCase {
    func testGapArmsAfterOneHundredMillisecondsAndStaysOpen() {
        var hover = LaunchpadInsertionHover()
        XCTAssertNil(hover.update(boundary: 3, point: CGPoint(x: 200, y: 100), now: 0))
        XCTAssertNil(hover.update(boundary: 3, point: CGPoint(x: 203, y: 102), now: 0.099))
        XCTAssertEqual(hover.update(boundary: 3, point: CGPoint(x: 203, y: 102), now: 0.1), 3)
        XCTAssertEqual(hover.update(boundary: 3, point: CGPoint(x: 219, y: 105), now: 4), 3)
    }

    func testMovingWithinAGapOrEnteringAnotherGapRestartsTheDwell() {
        var hover = LaunchpadInsertionHover()
        XCTAssertNil(hover.update(boundary: 2, point: CGPoint(x: 200, y: 100), now: 0))
        XCTAssertNil(hover.update(boundary: 2, point: CGPoint(x: 211, y: 100), now: 0.08))
        XCTAssertNil(hover.update(boundary: 2, point: CGPoint(x: 211, y: 100), now: 0.17))
        XCTAssertEqual(hover.update(boundary: 2, point: CGPoint(x: 211, y: 100), now: 0.19), 2)
        XCTAssertNil(hover.update(boundary: 4, point: CGPoint(x: 380, y: 100), now: 0.20))
        XCTAssertNil(hover.activeBoundary)
        XCTAssertEqual(hover.update(boundary: 4, point: CGPoint(x: 380, y: 100), now: 0.31), 4)
        hover.reset()
        XCTAssertNil(hover.update(boundary: 4, point: CGPoint(x: 380, y: 100), now: 2))
    }

    func testSideAndVerticalApproachesAllowInsertionWhileIconsStillOverlap() {
        XCTAssertNil(boundary(x: 300))
        XCTAssertNil(boundary(x: 322, y: 136))
        XCTAssertEqual(boundary(x: 176), 1)
        XCTAssertEqual(boundary(x: 244), 1)
        XCTAssertEqual(boundary(x: 300, y: 54), 1)
        XCTAssertEqual(boundary(x: 300, y: 170), 2)
        XCTAssertEqual(boundary(x: 30), 0)
        XCTAssertEqual(boundary(x: 570, y: 310), 7)
        XCTAssertNil(boundary(x: 750, y: 310))
    }

    func testDiagonalOverlapArmsWhenTheAreaFallsBelowThirtyPercent() {
        XCTAssertNil(boundary(x: 349, y: 61))
        XCTAssertEqual(boundary(x: 349, y: 59), 2)
    }

    func testSmallMovementKeepsAnArmedBoundaryAtAnIconEdgeOrBetweenRows() {
        XCTAssertNil(boundary(x: 172))
        XCTAssertEqual(boundary(x: 172, retaining: 1), 1)
        XCTAssertNil(boundary(x: 163, retaining: 1))
        XCTAssertEqual(boundary(x: 300, y: 211), 5)
        XCTAssertEqual(boundary(x: 300, y: 211, retaining: 2), 2)
        XCTAssertEqual(boundary(x: 300, y: 235, retaining: 2), 5)
    }

    func testPreviewStaysOpenAtItsActualSlotAndNearItsActivationPoint() {
        var hover = LaunchpadInsertionHover()
        let activation = CGPoint(x: 210, y: 110)
        let slotCenter = CGPoint(x: 300, y: 110)
        let cell = CGSize(width: 180, height: 200)

        XCTAssertNil(hover.update(boundary: 1, point: activation, now: 0))
        XCTAssertNil(hover.retainedBoundary(at: slotCenter, openSlotCenter: slotCenter, cellSize: cell))
        XCTAssertEqual(hover.update(boundary: 1, point: activation, now: 0.1), 1)

        XCTAssertNil(boundary(x: 300))
        XCTAssertEqual(hover.retainedBoundary(at: slotCenter, openSlotCenter: slotCenter, cellSize: cell), 1)
        XCTAssertEqual(hover.retainedBoundary(
            at: CGPoint(x: 180, y: 142), openSlotCenter: slotCenter, cellSize: cell
        ), 1)
        XCTAssertNil(hover.retainedBoundary(
            at: CGPoint(x: 410, y: 110), openSlotCenter: slotCenter, cellSize: cell
        ))

        hover.reset()
        XCTAssertNil(hover.retainedBoundary(at: slotCenter, openSlotCenter: slotCenter, cellSize: cell))
    }

    func testCompactGridAllowsInsertionAtTheSeamEvenWhenBothIconsOverlap() {
        func compactBoundary(x: CGFloat) -> Int? {
            LaunchpadInsertionHover.boundary(
                at: CGPoint(x: x, y: 80), firstRowY: 80,
                cellSize: CGSize(width: 156, height: 170), iconWidth: 128,
                columns: 4, itemCount: 4, leadingX: { _ in 100 }
            )
        }
        XCTAssertNil(compactBoundary(x: 155))
        XCTAssertEqual(compactBoundary(x: 178), 1)
    }

    func testHitBandUsesTheLeadingEdgeOfACenteredCanvasRow() {
        let boundary = LaunchpadInsertionHover.boundary(
            at: CGPoint(x: 270, y: 310), firstRowY: 110,
            cellSize: CGSize(width: 180, height: 200), iconWidth: 110,
            columns: 4, itemCount: 6, leadingX: { $0 == 0 ? 0 : 180 }
        )
        XCTAssertEqual(boundary, 5)
    }

    func testMovementEasesInAndOutAndFinishesAtTheTarget() {
        XCTAssertEqual(LaunchpadInsertionHover.movementProgress(0), 0)
        XCTAssertLessThan(LaunchpadInsertionHover.movementProgress(0.25), 0.25)
        XCTAssertEqual(LaunchpadInsertionHover.movementProgress(0.5), 0.5)
        XCTAssertGreaterThan(LaunchpadInsertionHover.movementProgress(0.75), 0.75)
        XCTAssertEqual(LaunchpadInsertionHover.movementProgress(1), 1)
    }

    private func boundary(x: CGFloat, y: CGFloat = 110, retaining: Int? = nil) -> Int? {
        LaunchpadInsertionHover.boundary(
            at: CGPoint(x: x, y: y), firstRowY: 110,
            cellSize: CGSize(width: 180, height: 200), iconWidth: 110,
            columns: 4, itemCount: 7, retaining: retaining, leadingX: { _ in 120 }
        )
    }
}
