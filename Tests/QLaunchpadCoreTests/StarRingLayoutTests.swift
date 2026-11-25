import XCTest
@testable import QLaunchpadCore

final class StarRingLayoutTests: XCTestCase {
    private let viewport = CGSize(width: 1440, height: 900)

    func testCenterAndSuccessiveRingsHaveTheExpectedCapacity() {
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 19, arrangement: .starRing)
        XCTAssertEqual(metrics.screenCenter(globalIndex: 0, scale: 1, pan: .zero), metrics.viewportCenter)
        for index in 1..<19 {
            let point = metrics.screenCenter(globalIndex: Double(index), scale: 1, pan: .zero)
            let radius = hypot(
                (point.x - metrics.viewportCenter.x) / metrics.cellWidth,
                (point.y - metrics.viewportCenter.y) / metrics.cellHeight
            )
            XCTAssertEqual(radius, index <= 6 ? 1 : 2, accuracy: 0.001)
        }
    }

    func testLargeCatalogHitTestingMatchesEveryDrawnSlotAfterPanAndZoom() {
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 10_000, arrangement: .starRing)
        let pan = CGPoint(x: 75.5, y: -105)
        for index in 0..<10_000 {
            let point = metrics.screenCenter(globalIndex: Double(index), scale: 0.4, pan: pan)
            XCTAssertEqual(metrics.itemIndex(atTopLeftPoint: point, scale: 0.4, pan: pan), index)
        }
        XCTAssertNil(metrics.itemIndex(atTopLeftPoint: CGPoint(x: -10_000, y: -10_000), scale: 0.4, pan: pan))
    }

    func testIncompleteOuterRingIsBalanced() {
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 9, arrangement: .starRing)
        let first = metrics.screenCenter(globalIndex: 7, scale: 1, pan: .zero)
        let other = metrics.screenCenter(globalIndex: 8, scale: 1, pan: .zero)
        XCTAssertEqual((first.x + other.x) / 2, metrics.viewportCenter.x, accuracy: 0.001)
        XCTAssertEqual((first.y + other.y) / 2, metrics.viewportCenter.y, accuracy: 0.001)
    }

    func testStartingZoomShowsTheOuterRingBelowTheSearchArea() {
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 58, arrangement: .starRing)
        let scale = metrics.viewportFillingScale
        XCTAssertGreaterThan(scale, metrics.fittedScale)
        for index in 0..<metrics.itemCount {
            let point = metrics.screenCenter(globalIndex: Double(index), scale: scale, pan: .zero)
            XCTAssertGreaterThanOrEqual(point.y - 64 * scale, 120)
            XCTAssertLessThanOrEqual(point.y + 64 * scale, viewport.height - 96)
        }
    }

    func testGapArmsClockwiseInsertionWhileIconCenterCanStillOpenAGroup() {
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 7, arrangement: .starRing)
        let first = metrics.screenCenter(globalIndex: 1, scale: 0.75, pan: .zero)
        let second = metrics.screenCenter(globalIndex: 2, scale: 0.75, pan: .zero)
        let gap = CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
        XCTAssertNil(metrics.starRingInsertionBoundary(at: first, scale: 0.75, pan: .zero))
        XCTAssertEqual(metrics.starRingInsertionBoundary(at: gap, scale: 0.75, pan: .zero), 2)
        XCTAssertEqual(metrics.starRingNeighbor(from: 0, direction: CGVector(dx: 0, dy: -1)), 1)
        XCTAssertEqual(metrics.starRingNeighbor(from: 0, direction: CGVector(dx: 0, dy: 1)), 4)
    }

    func testAddingARingPreservesTheCameraRelativeToTheCenter() {
        let before = InfiniteCanvasMetrics(size: viewport, itemCount: 19, arrangement: .starRing)
        let after = InfiniteCanvasMetrics(size: viewport, itemCount: 20, arrangement: .starRing)
        let pan = CGPoint(x: 75, y: -60)
        let camera = after.cameraPreservingGridPoint(
            from: before, scale: 0.8, pan: pan, minimumScale: 0.12, maximumScale: 1
        )
        XCTAssertEqual(camera.scale, 0.8, accuracy: 0.001)
        XCTAssertEqual(camera.pan.x, pan.x, accuracy: 0.001)
        XCTAssertEqual(camera.pan.y, pan.y, accuracy: 0.001)
    }
}
