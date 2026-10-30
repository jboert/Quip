import XCTest
@testable import Quip

final class TerminalScrollPolicyTests: XCTestCase {
    func test_atTheBottomFollowsNewOutput() {
        XCTAssertTrue(TerminalScrollPolicy.isPinnedToBottom(contentHeight: 1000, offsetY: 600, visibleHeight: 400))
    }

    func test_nearTheBottomStillFollows() {
        XCTAssertTrue(TerminalScrollPolicy.isPinnedToBottom(contentHeight: 1000, offsetY: 570, visibleHeight: 400))
    }

    func test_scrolledUpStaysPut() {
        XCTAssertFalse(TerminalScrollPolicy.isPinnedToBottom(contentHeight: 1000, offsetY: 200, visibleHeight: 400))
    }

    func test_contentShorterThanTheViewFollows() {
        // A fresh view has no content yet; it must start at the bottom.
        XCTAssertTrue(TerminalScrollPolicy.isPinnedToBottom(contentHeight: 0, offsetY: 0, visibleHeight: 400))
    }

    // MARK: US-008 resolve

    private let buffer = (0..<100).map { "line \($0)" }

    private func anchor(_ index: Int, in lines: [String]) -> ScrollAnchor {
        TerminalScrollPolicy.anchor(lines: lines, firstVisible: index)!
    }

    func test_exact_sameBuffer() {
        XCTAssertEqual(TerminalScrollPolicy.resolve(anchor: anchor(30, in: buffer), lines: buffer), 30)
    }

    func test_shiftedBy40NewLines_findsTheSameText() {
        let grown = buffer + (0..<40).map { "new \($0)" }
        XCTAssertEqual(TerminalScrollPolicy.resolve(anchor: anchor(30, in: buffer), lines: grown), 30)
    }

    func test_scrolledOffTheTopByAnOldLine_dropping() {
        // The Mac sends the last N lines: 10 old lines fell off the top.
        let window = Array(buffer.dropFirst(10)) + (0..<10).map { "new \($0)" }
        XCTAssertEqual(TerminalScrollPolicy.resolve(anchor: anchor(30, in: buffer), lines: window), 20)
    }

    func test_duplicateLines_nearestToTheSavedDistanceWins() {
        var lines = Array(repeating: "noise", count: 50)
        lines[10] = "$ make"; lines[38] = "$ make"; lines[45] = "$ make"
        let saved = ScrollAnchor(lineHash: TerminalScrollPolicy.hash("$ make"), fromEnd: 10)   // index 39
        XCTAssertEqual(TerminalScrollPolicy.resolve(anchor: saved, lines: lines), 38)
    }

    func test_tie_goesToTheEarlierLine() {
        var lines = Array(repeating: "noise", count: 21)
        lines[8] = "x"; lines[12] = "x"
        let saved = ScrollAnchor(lineHash: TerminalScrollPolicy.hash("x"), fromEnd: 10)   // index 10
        XCTAssertEqual(TerminalScrollPolicy.resolve(anchor: saved, lines: lines), 8)
    }

    func test_repeatedLines_comeBackAtTheSamePlace() {
        // Blank lines and repeated prompts: only the distance tells them apart.
        let lines = Array(repeating: "", count: 10)
        XCTAssertEqual(TerminalScrollPolicy.resolve(anchor: anchor(7, in: lines), lines: lines), 7)
    }

    func test_lineGone_isNil() {
        let other = (0..<100).map { "other \($0)" }
        XCTAssertNil(TerminalScrollPolicy.resolve(anchor: anchor(30, in: buffer), lines: other))
    }

    func test_emptyBuffer_isNil() {
        XCTAssertNil(TerminalScrollPolicy.resolve(anchor: anchor(30, in: buffer), lines: []))
    }

    func test_savedDistanceBeyondTheBuffer_stillSearches() {
        let short = ["a", "b", "line 3"]
        let saved = ScrollAnchor(lineHash: TerminalScrollPolicy.hash("line 3"), fromEnd: 500)
        XCTAssertEqual(TerminalScrollPolicy.resolve(anchor: saved, lines: short), 2)
    }

    func test_anchorKeepsNoText() throws {
        let a = anchor(30, in: ["secret-token-abc"] + buffer)
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        XCTAssertFalse(json.contains("line 29"))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertNil(TerminalScrollPolicy.anchor(lines: buffer, firstVisible: 100))
    }
}
