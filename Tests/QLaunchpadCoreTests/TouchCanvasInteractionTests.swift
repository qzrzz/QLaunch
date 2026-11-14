import XCTest
@testable import QLaunchpadCore

final class TouchCanvasInteractionTests: XCTestCase {
    func testSecondRecognizerDoesNotTakeOwnershipAgain() {
        var interaction = TouchCanvasInteraction()
        XCTAssertFalse(interaction.isActive)
        XCTAssertTrue(interaction.begin(.pan))
        XCTAssertFalse(interaction.begin(.magnification))
        XCTAssertTrue(interaction.isActive)
    }

    func testPointerStaysBlockedUntilBothRecognizersFinishInEitherOrder() {
        for first in [TouchCanvasInteraction.Gesture.pan, .magnification] {
            let second: TouchCanvasInteraction.Gesture = first == .pan ? .magnification : .pan
            var interaction = TouchCanvasInteraction()
            interaction.begin(first)
            interaction.begin(second)
            interaction.end(first)
            XCTAssertTrue(interaction.isActive)
            interaction.end(second)
            XCTAssertFalse(interaction.isActive)
        }
    }

    func testCancellationOfUnstartedRecognizerDoesNotReleaseActiveGesture() {
        var interaction = TouchCanvasInteraction()
        interaction.begin(.magnification)
        interaction.end(.pan)
        XCTAssertTrue(interaction.isActive)
        interaction.end(.magnification)
        XCTAssertFalse(interaction.isActive)
    }

    func testDismissalResetsBothRecognizersAndAllowsNewSession() {
        var interaction = TouchCanvasInteraction()
        interaction.begin(.pan)
        interaction.begin(.magnification)
        interaction.reset()
        XCTAssertFalse(interaction.isActive)
        // Late cancellation callbacks from the old session are harmless.
        interaction.end(.pan)
        interaction.end(.magnification)
        XCTAssertTrue(interaction.begin(.magnification))
    }
}
