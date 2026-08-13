import XCTest
@testable import QLaunchpadCore

final class LaunchpadAutoLayoutTests: XCTestCase {
    func testNameAscendingAndDescending() {
        let apps = [
            app("c", name: "Safari"),
            app("a", name: "Mail"),
            app("b", name: "Xcode"),
            app("d", name: "Mail", path: "/Z/Mail.app")
        ]
        XCTAssertEqual(
            LaunchpadAutoLayoutSorter.sortedIDs(apps, kind: .nameAscending),
            ["a", "d", "c", "b"]
        )
        XCTAssertEqual(
            LaunchpadAutoLayoutSorter.sortedIDs(apps, kind: .nameDescending),
            ["b", "c", "a", "d"]
        )
    }

    func testRecentlyUsedPutsNewestFirstAndNilLast() {
        let newer = Date(timeIntervalSince1970: 200)
        let older = Date(timeIntervalSince1970: 100)
        let apps = [
            app("none", name: "Never", lastUsedAt: nil),
            app("old", name: "Old", lastUsedAt: older),
            app("new", name: "New", lastUsedAt: newer)
        ]
        XCTAssertEqual(
            LaunchpadAutoLayoutSorter.sortedIDs(apps, kind: .recentlyUsed),
            ["new", "old", "none"]
        )
    }

    func testInstallDateAscendingAndDescending() {
        let first = Date(timeIntervalSince1970: 10)
        let second = Date(timeIntervalSince1970: 20)
        let apps = [
            app("unknown", name: "Unknown", installedAt: nil),
            app("later", name: "Later", installedAt: second),
            app("earlier", name: "Earlier", installedAt: first)
        ]
        XCTAssertEqual(
            LaunchpadAutoLayoutSorter.sortedIDs(apps, kind: .installDateAscending),
            ["earlier", "later", "unknown"]
        )
        XCTAssertEqual(
            LaunchpadAutoLayoutSorter.sortedIDs(apps, kind: .installDateDescending),
            ["later", "earlier", "unknown"]
        )
    }

    func testIconColorGroupsSimilarHuesAndPutsNeutralsLast() {
        let red = LaunchpadIconColor(hue: 0.02, saturation: 0.8, brightness: 0.7, isChromatic: true)
        let orange = LaunchpadIconColor(hue: 0.08, saturation: 0.7, brightness: 0.7, isChromatic: true)
        let blue = LaunchpadIconColor(hue: 0.62, saturation: 0.8, brightness: 0.6, isChromatic: true)
        let gray = LaunchpadIconColor(hue: 0, saturation: 0, brightness: 0.3, isChromatic: false)
        let white = LaunchpadIconColor(hue: 0, saturation: 0, brightness: 0.95, isChromatic: false)
        let apps = [
            app("blue", name: "Blue", color: blue),
            app("gray", name: "Gray", color: gray),
            app("orange", name: "Orange", color: orange),
            app("white", name: "White", color: white),
            app("red", name: "Red", color: red),
            app("pending", name: "Pending", color: nil)
        ]
        XCTAssertEqual(
            LaunchpadAutoLayoutSorter.sortedIDs(apps, kind: .iconColor),
            ["red", "orange", "blue", "gray", "white", "pending"]
        )
    }

    func testLayoutModeStorageRoundTrip() {
        XCTAssertEqual(LaunchpadLayoutMode(storageValue: nil), .user)
        XCTAssertEqual(LaunchpadLayoutMode(storageValue: "user"), .user)
        XCTAssertEqual(LaunchpadLayoutMode(storageValue: "nope"), .user)
        XCTAssertEqual(
            LaunchpadLayoutMode(storageValue: "auto.iconColor"),
            .auto(.iconColor)
        )
        XCTAssertEqual(LaunchpadLayoutMode.auto(.nameDescending).storageValue, "auto.nameDescending")
        XCTAssertTrue(LaunchpadLayoutMode.user.isUser)
        XCTAssertFalse(LaunchpadLayoutMode.auto(.recentlyUsed).isUser)
    }

    func testSelectorIDParse() {
        let user = LaunchpadLayoutSelectorID.parse(LaunchpadLayoutSelectorID.user("default"))
        XCTAssertEqual(user.profileID, "default")
        XCTAssertNil(user.autoKind)

        let auto = LaunchpadLayoutSelectorID.parse(
            LaunchpadLayoutSelectorID.auto(.installDateAscending)
        )
        XCTAssertNil(auto.profileID)
        XCTAssertEqual(auto.autoKind, .installDateAscending)

        let invalid = LaunchpadLayoutSelectorID.parse("auto:not-a-kind")
        XCTAssertNil(invalid.profileID)
        XCTAssertNil(invalid.autoKind)
    }

    private func app(
        _ id: String,
        name: String,
        path: String? = nil,
        lastUsedAt: Date? = nil,
        installedAt: Date? = nil,
        color: LaunchpadIconColor? = nil
    ) -> LaunchpadAutoLayoutApp {
        LaunchpadAutoLayoutApp(
            id: id,
            name: name,
            path: path ?? "/Applications/\(name).app",
            lastUsedAt: lastUsedAt,
            installedAt: installedAt,
            color: color
        )
    }
}
