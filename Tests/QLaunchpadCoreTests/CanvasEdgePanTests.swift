import CoreGraphics
import XCTest
@testable import QLaunchpadCore

final class CanvasEdgePanTests: XCTestCase {
    let bounds = CGSize(width: 1440, height: 900)
    let inset: CGFloat = CanvasEdgePan.defaultEdgeInset

    func testDefaultInsetIsCompact() {
        XCTAssertEqual(CanvasEdgePan.defaultEdgeInset, 32)
    }

    func testCenterPointerIsNotInEdgeZone() {
        let center = CGPoint(x: 720, y: 450)
        XCTAssertFalse(CanvasEdgePan.isPointerInEdgeZone(pointer: center, bounds: bounds, edgeInset: inset))
    }

    func testEdgeBoundariesAreInEdgeZone() {
        // Left (< 32)
        XCTAssertTrue(CanvasEdgePan.isPointerInEdgeZone(pointer: CGPoint(x: 10, y: 450), bounds: bounds, edgeInset: inset))
        // Right (> 1440 - 32 = 1408)
        XCTAssertTrue(CanvasEdgePan.isPointerInEdgeZone(pointer: CGPoint(x: 1430, y: 450), bounds: bounds, edgeInset: inset))
        // Top (< 32)
        XCTAssertTrue(CanvasEdgePan.isPointerInEdgeZone(pointer: CGPoint(x: 720, y: 10), bounds: bounds, edgeInset: inset))
        // Bottom (> 900 - 32 = 868)
        XCTAssertTrue(CanvasEdgePan.isPointerInEdgeZone(pointer: CGPoint(x: 720, y: 890), bounds: bounds, edgeInset: inset))
    }

    func testPointerExactlyAtInsetThreshold() {
        let exactlyAtInset = CGPoint(x: 32, y: 32)
        XCTAssertFalse(CanvasEdgePan.isPointerInEdgeZone(pointer: exactlyAtInset, bounds: bounds, edgeInset: inset))

        let justInsideEdge = CGPoint(x: 31.9, y: 450)
        XCTAssertTrue(CanvasEdgePan.isPointerInEdgeZone(pointer: justInsideEdge, bounds: bounds, edgeInset: inset))

        let safelyInside = CGPoint(x: 33, y: 450)
        XCTAssertFalse(CanvasEdgePan.isPointerInEdgeZone(pointer: safelyInside, bounds: bounds, edgeInset: inset))
    }

    func testSmallBoundsClampsInsetToQuarterDimension() {
        let smallBounds = CGSize(width: 100, height: 100)
        // 100 * 0.25 = 25 < 32
        XCTAssertEqual(CanvasEdgePan.horizontalInset(boundsWidth: 100, edgeInset: 32), 25)
        XCTAssertEqual(CanvasEdgePan.verticalInset(boundsHeight: 100, edgeInset: 32), 25)

        // Point at 30 is safe in 100x100 when inset is clamped to 25
        XCTAssertFalse(CanvasEdgePan.isPointerInEdgeZone(pointer: CGPoint(x: 30, y: 30), bounds: smallBounds, edgeInset: 32))
        // Point at 20 is in edge zone
        XCTAssertTrue(CanvasEdgePan.isPointerInEdgeZone(pointer: CGPoint(x: 20, y: 30), bounds: smallBounds, edgeInset: 32))
    }

    func testPlainSpaceKeyIdentification() {
        XCTAssertTrue(CanvasSpacePan.isPlainSpace(keyCode: 49, hasCommand: false, hasControl: false, hasOption: false))
        // Disqualify other keys
        XCTAssertFalse(CanvasSpacePan.isPlainSpace(keyCode: 50, hasCommand: false, hasControl: false, hasOption: false))
        // Disqualify Command + Space
        XCTAssertFalse(CanvasSpacePan.isPlainSpace(keyCode: 49, hasCommand: true, hasControl: false, hasOption: false))
        // Disqualify Control + Space
        XCTAssertFalse(CanvasSpacePan.isPlainSpace(keyCode: 49, hasCommand: false, hasControl: true, hasOption: false))
        // Disqualify Option + Space
        XCTAssertFalse(CanvasSpacePan.isPlainSpace(keyCode: 49, hasCommand: false, hasControl: false, hasOption: true))
    }
}
