import QLaunchpadCore
import XCTest

final class TrackpadCanvasPinchTests: XCTestCase {
    func testPinchScalesInBothDirectionsAndCanReverseWithoutLifting() throws {
        var pinch = TrackpadCanvasPinch()
        XCTAssertNil(pinch.update(pair(distance: 0.3)))
        let inward = try factor(pinch.update(pair(distance: 0.24)))
        let outward = try factor(pinch.update(pair(distance: 0.3).reversed()))
        XCTAssertEqual(inward, 0.8, accuracy: 0.0001)
        XCTAssertEqual(outward, 1, accuracy: 0.0001)
        XCTAssertEqual(pinch.update([]), .ended)
    }

    func testTwoFingerPanDoesNotStartZoom() {
        var pinch = TrackpadCanvasPinch()
        XCTAssertNil(pinch.update(pair(distance: 0.3)))
        XCTAssertNil(pinch.update(pair(distance: 0.295, shift: 0.04)))
        XCTAssertNil(pinch.update(pair(distance: 0.23, shift: 0.04)))
        XCTAssertNil(pinch.update([]))
    }

    func testTwoContactsLeftAfterFourFingerSpreadDoNotStartZoom() throws {
        var pinch = TrackpadCanvasPinch()
        let extra = [TrackpadTouch(id: 2, x: 0.2, y: 0.2), TrackpadTouch(id: 3, x: 0.8, y: 0.2)]
        XCTAssertNil(pinch.update(pair(distance: 0.3) + extra))
        XCTAssertNil(pinch.update(pair(distance: 0.3)))
        XCTAssertNil(pinch.update(pair(distance: 0.2)))
        XCTAssertNil(pinch.update([]))
        XCTAssertNil(pinch.update(pair(distance: 0.3)))
        XCTAssertLessThan(try factor(pinch.update(pair(distance: 0.2))), 1)
    }

    private func pair(distance: Double, shift: Double = 0) -> [TrackpadTouch] {
        [
            TrackpadTouch(id: 0, x: 0.5 + shift - distance / 2, y: 0.5),
            TrackpadTouch(id: 1, x: 0.5 + shift + distance / 2, y: 0.5),
        ]
    }

    private func factor(_ event: TrackpadCanvasPinch.Event?) throws -> Double {
        guard case .changed(let factor) = try XCTUnwrap(event) else {
            XCTFail("Expected a magnification event")
            return 1
        }
        return factor
    }
}
