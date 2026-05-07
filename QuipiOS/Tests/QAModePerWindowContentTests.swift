#if os(iOS)
import XCTest
@testable import Quip

@MainActor
final class QAModePerWindowContentTests: XCTestCase {

    /// Updating one windowId's content does not bleed into another.
    func testPerWindowIdSlotsAreIndependent() {
        var text: [String: String] = [:]
        var screenshot: [String: String] = [:]
        var urls: [String: [String]] = [:]

        ContentMapMutations.applyContent(
            windowId: "win-A",
            text: "alpha output",
            screenshot: "data:imageA",
            urls: ["http://localhost:3000"],
            into: &text, &screenshot, &urls
        )
        ContentMapMutations.applyContent(
            windowId: "win-B",
            text: "beta output",
            screenshot: nil,
            urls: [],
            into: &text, &screenshot, &urls
        )

        XCTAssertEqual(text["win-A"], "alpha output")
        XCTAssertEqual(text["win-B"], "beta output")
        XCTAssertEqual(screenshot["win-A"], "data:imageA")
        XCTAssertNil(screenshot["win-B"])
        XCTAssertEqual(urls["win-A"], ["http://localhost:3000"])
        XCTAssertEqual(urls["win-B"], [])
    }

    /// Pair-clear purges both windowIds' slots so v1's "exit QA returns to grid"
    /// path doesn't leak last-seen content into the next pair session.
    func testPairClearPurgesBothPairWindows() {
        var text: [String: String] = ["sim-1": "s", "term-1": "t", "other": "o"]
        var screenshot: [String: String] = ["sim-1": "ss", "term-1": "ts"]
        var urls: [String: [String]] = ["sim-1": [], "term-1": ["u"]]

        ContentMapMutations.purgePairContent(
            pair: ("sim-1", "term-1"),
            from: &text, &screenshot, &urls
        )

        XCTAssertNil(text["sim-1"])
        XCTAssertNil(text["term-1"])
        XCTAssertEqual(text["other"], "o", "non-pair entries are untouched")
        XCTAssertNil(screenshot["sim-1"])
        XCTAssertNil(screenshot["term-1"])
        XCTAssertNil(urls["sim-1"])
        XCTAssertNil(urls["term-1"])
    }
}
#endif
