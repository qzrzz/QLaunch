import XCTest
@testable import QLaunchpadCore

final class InfiniteCanvasMetricsTests: XCTestCase {
    private let viewport = CGSize(width: 1440, height: 900)

    func testTouchZoomKeepsWorldPointUnderOffCenterFinger() {
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 128, maximumScale: 2)
        let anchor = CGPoint(x: 810, y: 370)
        let original = metrics.worldPoint(atScreenPoint: anchor, scale: 1, pan: CGPoint(x: 20, y: -15))
        let zoomed = metrics.cameraZoomed(
            scale: 1, pan: CGPoint(x: 20, y: -15), factor: 1.4, anchor: anchor,
            minimumScale: 0.12, maximumScale: 2
        )
        let after = metrics.worldPoint(atScreenPoint: anchor, scale: zoomed.scale, pan: zoomed.pan)
        XCTAssertEqual(zoomed.scale, 1.4, accuracy: 0.0001)
        XCTAssertEqual(after.x, original.x, accuracy: 0.0001)
        XCTAssertEqual(after.y, original.y, accuracy: 0.0001)
    }

    func testTouchZoomClampsScaleAndPanAtBothLimits() {
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 128, maximumScale: 2)
        for (factor, expectedScale) in [(0.01, 0.25), (100.0, 2.0)] {
            let camera = metrics.cameraZoomed(
                scale: 1, pan: CGPoint(x: 10_000, y: -10_000), factor: factor,
                anchor: CGPoint(x: 90, y: 80), minimumScale: 0.25, maximumScale: 2
            )
            XCTAssertEqual(camera.scale, expectedScale, accuracy: 0.0001)
            XCTAssertEqual(camera.pan, metrics.clampedPan(camera.pan, scale: camera.scale))
        }
    }

    func testTouchZoomCanReverseWithoutCameraDrift() {
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 128, maximumScale: 2)
        let anchor = CGPoint(x: 820, y: 410)
        let initialPan = CGPoint(x: 30, y: -10)
        let enlarged = metrics.cameraZoomed(
            scale: 1, pan: initialPan, factor: 1.5, anchor: anchor,
            minimumScale: 0.12, maximumScale: 2
        )
        let restored = metrics.cameraZoomed(
            scale: enlarged.scale, pan: enlarged.pan, factor: 1 / 1.5, anchor: anchor,
            minimumScale: 0.12, maximumScale: 2
        )
        XCTAssertEqual(restored.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(restored.pan.x, initialPan.x, accuracy: 0.0001)
        XCTAssertEqual(restored.pan.y, initialPan.y, accuracy: 0.0001)
    }

    func testReorderDoesNotChangeWorldSize() {
        let before = InfiniteCanvasMetrics(size: viewport, itemCount: 40)
        let after = InfiniteCanvasMetrics(size: viewport, itemCount: 40)
        XCTAssertEqual(before.worldSize, after.worldSize)
        XCTAssertEqual(before.rows, after.rows)
        XCTAssertEqual(before.viewportFillingScale, after.viewportFillingScale, accuracy: 0.0001)
    }

    func testCameraPreservesScaleWhenItemCountChanges() {
        let before = InfiniteCanvasMetrics(size: viewport, itemCount: 40)
        let after = InfiniteCanvasMetrics(size: viewport, itemCount: 39)
        let scale: CGFloat = 1.35
        let pan = CGPoint(x: 80, y: -40)

        let preserved = after.cameraPreservingGridPoint(
            from: before,
            scale: scale,
            pan: pan,
            minimumScale: max(after.fittedScale, 0.12),
            maximumScale: 2
        )

        XCTAssertEqual(preserved.scale, scale, accuracy: 0.0001)
    }

    func testCameraKeepsViewportCenterOnTheSameGridPoint() {
        let before = InfiniteCanvasMetrics(size: viewport, itemCount: 40)
        let after = InfiniteCanvasMetrics(size: viewport, itemCount: 24)
        let scale: CGFloat = 1.2
        let pan = CGPoint(x: 60, y: 30)
        let originalGrid = before.gridPoint(
            forWorldPoint: before.worldPoint(
                atScreenPoint: before.viewportCenter,
                scale: scale,
                pan: pan
            )
        )

        let preserved = after.cameraPreservingGridPoint(
            from: before,
            scale: scale,
            pan: pan,
            minimumScale: max(after.fittedScale, 0.12),
            maximumScale: 2
        )
        let newGrid = after.gridPoint(
            forWorldPoint: after.worldPoint(
                atScreenPoint: after.viewportCenter,
                scale: preserved.scale,
                pan: preserved.pan
            )
        )

        XCTAssertEqual(newGrid.x, originalGrid.x, accuracy: 0.0001)
        XCTAssertEqual(newGrid.y, originalGrid.y, accuracy: 0.0001)
    }

    func testCameraKeepsScaleAcrossViewportResize() {
        let before = InfiniteCanvasMetrics(size: viewport, itemCount: 48)
        let after = InfiniteCanvasMetrics(
            size: CGSize(width: 1680, height: 1050),
            itemCount: 48
        )
        let scale: CGFloat = 1.4
        let pan = CGPoint(x: -50, y: 20)

        let preserved = after.cameraPreservingGridPoint(
            from: before,
            scale: scale,
            pan: pan,
            minimumScale: max(after.fittedScale, 0.12),
            maximumScale: 2
        )

        XCTAssertEqual(preserved.scale, scale, accuracy: 0.0001)
    }

    func testScreenAndWorldRoundTrip() {
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 32)
        let scale: CGFloat = 1.15
        let pan = CGPoint(x: 25, y: -18)
        let screen = CGPoint(x: 700, y: 400)
        let world = metrics.worldPoint(atScreenPoint: screen, scale: scale, pan: pan)
        let restoredPan = metrics.pan(placing: world, atScreenPoint: screen, scale: scale)
        XCTAssertEqual(restoredPan.x, pan.x, accuracy: 0.0001)
        XCTAssertEqual(restoredPan.y, pan.y, accuracy: 0.0001)
    }
}
