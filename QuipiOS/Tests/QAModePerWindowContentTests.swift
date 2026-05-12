#if os(iOS)
import XCTest
@testable import Quip

@MainActor
final class QAModePerWindowContentTests: XCTestCase {

    /// The Mac may publish iTerm's display name as "iTerm" even though the
    /// terminal enum is named `iterm2`. Pairing must keep accepting that wire
    /// value or the QA picker shows "No terminals detected."
    func testItermDisplayNameIsTerminal() {
        let window = WindowState(
            id: "term-1",
            name: "iTerm - Quip",
            app: "iTerm",
            folder: "Quip",
            enabled: true,
            frame: WindowFrame(x: 0, y: 0, width: 100, height: 100),
            state: "neutral",
            color: "#14B8A6"
        )

        XCTAssertTrue(window.isTerminal)
    }

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
        // Sticky semantics: empty urls leaves slot unwritten (no prior, so nil).
        XCTAssertNil(urls["win-B"])
    }

    /// A refresh whose Mac-side capture transiently fails (nil/empty screenshot
    /// or empty urls) must not drop the prior content. Otherwise the QA pane
    /// blanks for one tick every time a screencapture call hiccups.
    func testApplyContentIsStickyOnNilScreenshotAndEmptyURLs() {
        var text: [String: String] = [:]
        var screenshot: [String: String] = [:]
        var urls: [String: [String]] = [:]

        ContentMapMutations.applyContent(
            windowId: "win-A",
            text: "first",
            screenshot: "data:imageA",
            urls: ["http://localhost:3000"],
            into: &text, &screenshot, &urls
        )
        ContentMapMutations.applyContent(
            windowId: "win-A",
            text: "second",
            screenshot: nil,
            urls: [],
            into: &text, &screenshot, &urls
        )

        XCTAssertEqual(text["win-A"], "second", "text always overwrites")
        XCTAssertEqual(screenshot["win-A"], "data:imageA", "nil screenshot must not clear prior")
        XCTAssertEqual(urls["win-A"], ["http://localhost:3000"], "empty urls must not clear prior")

        ContentMapMutations.applyContent(
            windowId: "win-A",
            text: "third",
            screenshot: "",
            urls: [],
            into: &text, &screenshot, &urls
        )
        XCTAssertEqual(screenshot["win-A"], "data:imageA", "empty-string screenshot must not clear prior")
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
