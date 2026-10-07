import XCTest
@testable import Quip

final class KeyColorsTests: XCTestCase {

    func testRoundTripsAndNormalizes() {
        let colors = KeyColors.setting("#4a90d9", for: "b:esc", in: [:])
        XCTAssertEqual(colors, ["b:esc": "#4A90D9"])
        XCTAssertEqual(KeyColors.decode(KeyColors.encode(colors)), colors)
    }

    func testResetRemovesOnlyThatButton() {
        let colors = ["b:esc": "#4A90D9", "pp": "#FF6B6B"]
        XCTAssertEqual(KeyColors.setting(nil, for: "b:esc", in: colors), ["pp": "#FF6B6B"])
    }

    func testMalformedColorLeavesTheMapAlone() {
        let colors = ["b:esc": "#4A90D9"]
        XCTAssertEqual(KeyColors.setting("blue", for: "b:esc", in: colors), colors)
    }

    /// A damaged blob (or a restored backup with one bad value) must not
    /// cost the user every other button's color.
    func testDecodeDropsBadValuesAndSurvivesGarbage() {
        XCTAssertEqual(KeyColors.decode(##"{"b:esc":"#4A90D9","pp":"nope"}"##), ["b:esc": "#4A90D9"])
        XCTAssertEqual(KeyColors.decode("not json"), [:])
        XCTAssertEqual(KeyColors.decode(""), [:])
    }

    func testTextColorFollowsContrast() {
        XCTAssertTrue(KeyColors.prefersDarkText(on: "#F8E71C"), "yellow")
        XCTAssertTrue(KeyColors.prefersDarkText(on: "#B8E986"), "pale green")
        XCTAssertTrue(KeyColors.prefersDarkText(on: "#FFFFFF"))
        XCTAssertFalse(KeyColors.prefersDarkText(on: "#9013FE"), "purple")
        XCTAssertFalse(KeyColors.prefersDarkText(on: "#D0021B"), "red")
        XCTAssertFalse(KeyColors.prefersDarkText(on: "#000000"))
    }
}
