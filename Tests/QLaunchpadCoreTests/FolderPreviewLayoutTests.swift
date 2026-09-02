import XCTest
@testable import QLaunchpadCore

final class FolderPreviewLayoutTests: XCTestCase {
    func testPreviewGridIsCenteredInTheFolder() {
        let center = CGPoint(x: 64, y: 64)
        let size: CGFloat = 128
        let first = FolderPreviewLayout.miniCenter(
            index: 0,
            folderCenter: center,
            folderSize: size,
            yIncreasesDown: true
        )
        let last = FolderPreviewLayout.miniCenter(
            index: 8,
            folderCenter: center,
            folderSize: size,
            yIncreasesDown: true
        )
        XCTAssertEqual(first.x + last.x, center.x * 2, accuracy: 0.001)
        XCTAssertEqual(first.y + last.y, center.y * 2, accuracy: 0.001)
        XCTAssertLessThan(first.x, center.x)
        XCTAssertLessThan(first.y, center.y)
        XCTAssertGreaterThan(last.x, center.x)
        XCTAssertGreaterThan(last.y, center.y)
    }

    func testCoreGraphicsOriginPutsTheFirstIconOnTop() {
        let center = CGPoint(x: 64, y: 64)
        let size: CGFloat = 128
        let topLeft = FolderPreviewLayout.miniCenter(
            index: 0,
            folderCenter: center,
            folderSize: size,
            yIncreasesDown: false
        )
        let bottomLeft = FolderPreviewLayout.miniCenter(
            index: 6,
            folderCenter: center,
            folderSize: size,
            yIncreasesDown: false
        )
        XCTAssertGreaterThan(topLeft.y, center.y)
        XCTAssertLessThan(bottomLeft.y, center.y)
        XCTAssertEqual(topLeft.x, bottomLeft.x, accuracy: 0.001)
    }

    func testMiniSizeScalesWithTheFolder() {
        XCTAssertEqual(FolderPreviewLayout.miniSize(in: 128), 22, accuracy: 0.001)
        XCTAssertEqual(FolderPreviewLayout.miniSize(in: 256), 44, accuracy: 0.001)
        XCTAssertEqual(FolderPreviewLayout.gap(in: 128), 4, accuracy: 0.001)
    }
}
