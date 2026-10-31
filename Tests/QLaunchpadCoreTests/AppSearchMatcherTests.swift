import XCTest
@testable import QLaunchpadCore

final class AppSearchMatcherTests: XCTestCase {
    func testNotesAreSearchableWithoutMatchingApplicationName() {
        XCTAssertEqual(AppSearchMatcher(query: "修图").rank(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.adobe.photoshop",
            pinyin: .empty,
            note: "工作用的修图工具"
        ), .existingMetadata)
    }

    func testNoteMatchingIgnoresCaseAndDiacritics() {
        XCTAssertEqual(AppSearchMatcher(query: " CAFE ").rank(
            name: "Notes",
            bundleIdentifier: "com.example.notes",
            pinyin: .empty,
            note: "Café planning"
        ), .existingMetadata)
    }

    func testNameRankingIsPreservedWhenNoteAlsoMatches() {
        XCTAssertEqual(AppSearchMatcher(query: "Notes").rank(
            name: "Notes",
            bundleIdentifier: "com.example.notes",
            pinyin: .empty,
            note: "Meeting notes"
        ), .exactName)
    }

    func testRemovingNoteRemovesItsSearchMatch() {
        XCTAssertNil(AppSearchMatcher(query: "修图").rank(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.adobe.photoshop",
            pinyin: .empty,
            note: ""
        ))
    }

    func testOrderedLettersMatchAdobePhotoshop() {
        let matcher = AppSearchMatcher(query: "ps")
        let rank = matcher.rank(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.adobe.photoshop",
            pinyin: .empty
        )

        XCTAssertEqual(rank, .orderedCharacters)
    }

    func testOrderedMatchIgnoresCaseAndSeparators() {
        let matcher = AppSearchMatcher(query: "P-S")
        let rank = matcher.rank(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.adobe.photoshop",
            pinyin: .empty
        )

        XCTAssertEqual(rank, .orderedCharacters)
    }

    func testCharactersMustAppearInQueryOrder() {
        let matcher = AppSearchMatcher(query: "pz")
        XCTAssertNil(matcher.rank(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.adobe.photoshop",
            pinyin: .empty
        ))
    }

    func testNameMatchesRankAheadOfExistingMetadata() {
        let nameMatcher = AppSearchMatcher(query: "photoshop")
        let metadataMatcher = AppSearchMatcher(query: "vendor")
        let nameRank = nameMatcher.rank(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.vendor.editor",
            pinyin: .empty
        )
        let metadataRank = metadataMatcher.rank(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.vendor.editor",
            pinyin: .empty
        )

        XCTAssertEqual(nameRank, .nameSubstring)
        XCTAssertEqual(metadataRank, .existingMetadata)
        XCTAssertLessThan(nameRank!, metadataRank!)
    }

    func testExactAndPrefixNameMatchesRankBeforeSubstring() {
        let exact = AppSearchMatcher(query: "Adobe Photoshop").rank(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.adobe.photoshop",
            pinyin: .empty
        )
        let prefix = AppSearchMatcher(query: "adobe").rank(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.adobe.photoshop",
            pinyin: .empty
        )
        let substring = AppSearchMatcher(query: "photoshop").rank(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.adobe.photoshop",
            pinyin: .empty
        )

        XCTAssertEqual(exact, .exactName)
        XCTAssertEqual(prefix, .namePrefix)
        XCTAssertEqual(substring, .nameSubstring)
        XCTAssertLessThan(exact!, prefix!)
        XCTAssertLessThan(prefix!, substring!)
    }

    func testPinyinMatchRemainsAvailableBeforeOrderedNameFallback() {
        let music = PinyinSearchMetadata.make(for: "音乐")
        let matcher = AppSearchMatcher(query: "yy")

        XCTAssertEqual(matcher.rank(
            name: "网易云音乐",
            bundleIdentifier: "com.netease.music",
            pinyin: music
        ), .existingMetadata)
    }

    func testEmptyQueryHasNoRank() {
        XCTAssertNil(AppSearchMatcher(query: " \n ").rank(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.adobe.photoshop",
            pinyin: .empty
        ))
    }
}
