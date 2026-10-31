import XCTest
@testable import QLaunchpadCore

final class AppNameTests: XCTestCase {
    func testCustomNameIsTrimmedAndOriginalIsPreserved() {
        let name = AppName(original: "Adobe Photoshop", custom: "  修图工具\n")
        XCTAssertEqual(name.display, "修图工具")
        XCTAssertEqual(name.custom, "修图工具")
        XCTAssertEqual(name.original, "Adobe Photoshop")
    }

    func testEmptyOrDefaultNameClearsOverride() {
        for custom in [nil, "", " \n", " Notes "] as [String?] {
            let name = AppName(original: "Notes", custom: custom)
            XCTAssertNil(name.custom)
            XCTAssertEqual(name.display, "Notes")
        }
    }

    func testCustomNameAndOriginalNameBothMatch() {
        let name = AppName(original: "Adobe Photoshop", custom: "修图工具")
        for query in ["修图工具", "Photoshop", "ps", "xiutu", "xtgj"] {
            XCTAssertNotNil(rank(query, name: name), query)
        }
        XCTAssertEqual(rank("修图工具", name: name), .exactName)
        XCTAssertEqual(rank("Adobe Photoshop", name: name), .exactName)
        XCTAssertNil(rank("浏览器", name: name))
    }

    func testOriginalPinyinStillMatchesAfterRename() {
        let name = AppName(original: "网易云音乐", custom: "Music")
        XCTAssertNotNil(rank("wyyy", name: name))
        XCTAssertNotNil(rank("yinyue", name: name))
        XCTAssertEqual(rank("Music", name: name), .exactName)
    }

    func testResetDropsCustomSearchKeys() {
        let renamed = AppName(original: "Photoshop", custom: "修图工具")
        let reset = AppName(original: renamed.original, custom: renamed.original, originalPinyin: renamed.originalPinyin)
        XCTAssertNil(rank("修图", name: reset))
        XCTAssertNil(rank("xtgj", name: reset))
        XCTAssertEqual(rank("Photoshop", name: reset), .exactName)
    }

    func testBestNameMatchWinsOverMetadataAndFuzzyMatches() {
        let name = AppName(original: "Adobe Photoshop", custom: "PS")
        XCTAssertEqual(rank("ps", name: name), .exactName)
        XCTAssertEqual(rank("adobe", name: name), .namePrefix)
    }

    private func rank(_ query: String, name: AppName) -> AppSearchMatchRank? {
        AppSearchMatcher(query: query).rank(
            name: name.display, bundleIdentifier: "com.example.app", pinyin: name.pinyin,
            alternateName: name.custom == nil ? nil : name.original,
            alternatePinyin: name.custom == nil ? .empty : name.originalPinyin
        )
    }
}
