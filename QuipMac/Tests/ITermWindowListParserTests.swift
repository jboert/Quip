import XCTest
@testable import Quip

final class ITermWindowListParserTests: XCTestCase {

    func test_parse_returnsEmptyOnEmptyString() {
        XCTAssertTrue(WindowManager.parseITermWindowList("").isEmpty)
    }

    func test_parse_singleWindow() {
        let input = "12345\tAB-CD-EF\tclaude\t/Users/dev/proj\tfalse\n"
        let parsed = WindowManager.parseITermWindowList(input)
        XCTAssertEqual(parsed.count, 1)
        let w = parsed[0]
        XCTAssertEqual(w.windowNumber, 12345)
        XCTAssertEqual(w.sessionId, "AB-CD-EF")
        XCTAssertEqual(w.title, "claude")
        XCTAssertEqual(w.cwd, "/Users/dev/proj")
        XCTAssertFalse(w.isMiniaturized)
    }

    func test_parse_multipleWindowsPreservesOrder() {
        let input = """
        1\tuuid-1\tfirst\t/a\tfalse
        2\tuuid-2\tsecond\t/b\ttrue
        3\tuuid-3\tthird\t/c\tfalse

        """
        let parsed = WindowManager.parseITermWindowList(input)
        XCTAssertEqual(parsed.map(\.windowNumber), [1, 2, 3])
        XCTAssertEqual(parsed.map(\.title), ["first", "second", "third"])
        XCTAssertEqual(parsed[1].isMiniaturized, true)
    }

    func test_parse_toleratesTitleAndPathPunctuation() {
        // Titles and cwds can contain colons, slashes, spaces, dashes.
        // The only reserved delimiter is TAB, which iTerm2 titles cannot
        // contain via normal usage.
        let input = "99\tABC\tfix: thing-1 (wip)\t/Users/dev/my proj/sub\tfalse\n"
        let parsed = WindowManager.parseITermWindowList(input)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].title, "fix: thing-1 (wip)")
        XCTAssertEqual(parsed[0].cwd, "/Users/dev/my proj/sub")
    }

    func test_parse_skipsMalformedLinesInstead_of_crashing() {
        // Missing fields, non-numeric window id — parser must drop and move on.
        let input = """
        1\tuuid-1\tok\t/a\tfalse
        not-a-number\tuuid-x\tbad\t/x\tfalse
        only-one-field
        2\tuuid-2\talso-ok\t/b\tfalse

        """
        let parsed = WindowManager.parseITermWindowList(input)
        XCTAssertEqual(parsed.map(\.windowNumber), [1, 2])
    }

    func test_parse_minimizedFlagCaseInsensitive() {
        let input = """
        1\tuuid-1\ta\t/a\tTRUE
        2\tuuid-2\tb\t/b\tTrue
        3\tuuid-3\tc\t/c\tfalse

        """
        let parsed = WindowManager.parseITermWindowList(input)
        XCTAssertEqual(parsed.map(\.isMiniaturized), [true, true, false])
    }
}
