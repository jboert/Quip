import XCTest
@testable import Quip

final class TerminalContentWindowTests: XCTestCase {
    func test_keepsTheNewestLinesUpToTheCap() {
        let lines = (1...2500).map { "line \($0)" }
        let tail = TerminalContentWindow.tail(lines.joined(separator: "\n"))
            .components(separatedBy: "\n")
        XCTAssertEqual(tail.count, TerminalContentWindow.maxLines)
        XCTAssertEqual(tail.first, "line 501")
        XCTAssertEqual(tail.last, "line 2500")
    }

    func test_shortContentPassesThroughUnchanged() {
        XCTAssertEqual(TerminalContentWindow.tail("a\nb\n"), "a\nb\n")
    }

    func test_capReachesWellPastOneScreen() {
        // 200 lines (about three screens) is what made scrolling up on the
        // phone run out almost immediately.
        XCTAssertGreaterThanOrEqual(TerminalContentWindow.maxLines, 2000)
    }

    func test_tidyCollapsesBlankRuns() {
        XCTAssertEqual(TerminalContentWindow.tidy("a\n\n\n   \nb"), "a\n\nb")
    }

    func test_tidyDropsUpdateNoticeFromFooterOnly() {
        let body = ["Update installed earlier, quoted in the transcript"]
            + (1...20).map { "line \($0)" }
            + ["✔ Update installed · Restart to update", "> "]
        let tidied = TerminalContentWindow.tidy(body.joined(separator: "\n"))
            .components(separatedBy: "\n")
        XCTAssertEqual(tidied.first, body.first)
        XCTAssertFalse(tidied.contains("✔ Update installed · Restart to update"))
        XCTAssertEqual(tidied.last, "> ")
    }
}
