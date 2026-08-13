import XCTest
@testable import QLaunchpadCore

final class PinyinSearchTests: XCTestCase {
    func testMusicMatchesYinYueInitialsAndFull() {
        let music = PinyinSearchMetadata.make(for: "音乐")
        XCTAssertTrue(music.matches("yy"), "乐 in 音乐 is yuè; initials should be yy")
        XCTAssertTrue(music.matches("yinyue"))
        XCTAssertTrue(music.matches("yue"))
        XCTAssertTrue(music.matches("yin"))
        // Unihan default lè stays available.
        XCTAssertTrue(music.matches("yl"))
        XCTAssertTrue(music.matches("yinle"))
        XCTAssertFalse(music.matches("zz"))
    }

    func testTraditionalMusicMatchesYinYue() {
        let music = PinyinSearchMetadata.make(for: "音樂")
        XCTAssertTrue(music.matches("yy"))
        XCTAssertTrue(music.matches("yinyue"))
    }

    func testHappyKeepsLeReading() {
        let happy = PinyinSearchMetadata.make(for: "快乐")
        XCTAssertTrue(happy.matches("kl"))
        XCTAssertTrue(happy.matches("kuaile"))
    }

    func testBandUsesYueReading() {
        let band = PinyinSearchMetadata.make(for: "乐团")
        XCTAssertTrue(band.matches("yt"))
        XCTAssertTrue(band.matches("yuetuan"))
        XCTAssertTrue(band.matches("lt"))
    }

    func testBankUsesHangReading() {
        let bank = PinyinSearchMetadata.make(for: "银行")
        XCTAssertTrue(bank.matches("yh"))
        XCTAssertTrue(bank.matches("yinhang"))
        XCTAssertTrue(bank.matches("yx"))
        XCTAssertTrue(bank.matches("yinxing"))
    }

    func testMixedLatinAndMusicMatchesYY() {
        let qqMusic = PinyinSearchMetadata.make(for: "QQ音乐")
        XCTAssertTrue(qqMusic.matches("yy"))
        XCTAssertTrue(qqMusic.matches("yinyue"))
        XCTAssertTrue(qqMusic.matches("qq"))
    }

    func testLongNameContainsMusicInitials() {
        let netease = PinyinSearchMetadata.make(for: "网易云音乐")
        XCTAssertTrue(netease.matches("yy"))
        XCTAssertTrue(netease.matches("yinyue"))
    }

    func testWeChatInitials() {
        let wechat = PinyinSearchMetadata.make(for: "微信")
        XCTAssertTrue(wechat.matches("wx"))
        XCTAssertTrue(wechat.matches("weixin"))
        XCTAssertTrue(wechat.matches("wei"))
        XCTAssertFalse(wechat.matches("yy"))
    }

    func testEnglishNameHasNoPinyin() {
        let music = PinyinSearchMetadata.make(for: "Music")
        XCTAssertFalse(music.matches("yy"))
        XCTAssertFalse(music.matches("music"))
        XCTAssertEqual(music, .empty)
    }

    func testEmptyQueryDoesNotMatch() {
        XCTAssertFalse(PinyinSearchMetadata.make(for: "音乐").matches(""))
    }

    func testChanganPrefersChang() {
        let changan = PinyinSearchMetadata.make(for: "长安")
        XCTAssertTrue(changan.matches("ca"))
        XCTAssertTrue(changan.matches("changan"))
        XCTAssertTrue(changan.matches("za"))
    }
}
