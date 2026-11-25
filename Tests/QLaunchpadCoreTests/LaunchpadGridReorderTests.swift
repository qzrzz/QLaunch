import XCTest
@testable import QLaunchpadCore

final class LaunchpadGridReorderTests: XCTestCase {
    func testDensePreviewOpensSpaceBeforeOrAfterAnItem() {
        let order = ["A", "B", "C", "D", "E"]
        XCTAssertEqual(
            LaunchpadGridReorder.inserting(["B"], in: order, at: 4),
            ["A", "C", "D", "B", "E"]
        )
        XCTAssertEqual(
            LaunchpadGridReorder.inserting(["D"], in: order, at: 1),
            ["A", "D", "B", "C", "E"]
        )
        XCTAssertNil(LaunchpadGridReorder.inserting(["B"], in: order, at: 2))
    }

    func testDensePreviewMovesASelectionAcrossPageBoundariesInOrder() {
        let order = ["A", "B", "C", "D", "E", "F", "G", "H"]
        XCTAssertEqual(
            LaunchpadGridReorder.inserting(["B", "D"], in: order, at: 7),
            ["A", "C", "E", "F", "G", "B", "D", "H"]
        )
        XCTAssertEqual(
            LaunchpadGridReorder.inserting(["B", "D"], in: order, at: order.count),
            ["A", "C", "E", "F", "G", "H", "B", "D"]
        )
        XCTAssertNil(LaunchpadGridReorder.inserting(["X"], in: order, at: 4))
    }

    func testFreePlacementPreviewSwapsAnOccupantAndLeavesEmptySlotsAlone() {
        let slots = ["A": 1, "B": 3, "C": 7]
        XCTAssertEqual(
            LaunchpadGridReorder.placements(["A"], in: slots, anchorID: "A", destination: 7, slotLimit: 8),
            ["A": 7, "C": 1]
        )
        XCTAssertEqual(
            LaunchpadGridReorder.placements(["A"], in: slots, anchorID: "A", destination: 4, slotLimit: 8),
            ["A": 4]
        )
        XCTAssertEqual(slots, ["A": 1, "B": 3, "C": 7])
    }

    func testFreePlacementPreviewDisplacesOccupantsInSlotOrder() {
        let slots = ["A": 0, "B": 2, "C": 4, "D": 6, "E": 8]
        XCTAssertEqual(
            LaunchpadGridReorder.placements(["A", "B"], in: slots, anchorID: "A", destination: 4, slotLimit: 10),
            ["A": 4, "B": 6, "C": 0, "D": 2]
        )
        XCTAssertEqual(
            LaunchpadGridReorder.placements(["A", "B"], in: slots, anchorID: "A", destination: 2, slotLimit: 10),
            ["A": 2, "B": 4, "C": 0]
        )
        XCTAssertNil(
            LaunchpadGridReorder.placements(["A", "B"], in: slots, anchorID: "A", destination: 8, slotLimit: 10)
        )
    }
}
