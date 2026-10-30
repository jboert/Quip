import XCTest
@testable import Quip

/// Locks the grid order (Q-58): the drag order holds, except that a pinned
/// window is always at the front, top left.
final class PhoneWindowOrderTests: XCTestCase {

    private func w(_ id: String, pinned: Bool = false) -> WindowState {
        WindowState(id: id, name: id, app: "iTerm2", enabled: true,
                    frame: WindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
                    state: "neutral", color: "#FFFFFF", isPinned: pinned)
    }

    func test_savedOrderWins_whenNothingIsPinned() {
        let shown = PhoneWindowOrder.display([w("a"), w("b"), w("c")], savedOrder: ["c", "a"])
        XCTAssertEqual(shown.map(\.id), ["c", "a", "b"], "unknown ids trail in incoming order")
    }

    func test_pinnedWindowIsFirst_evenWhenTheDragOrderPutItLast() {
        let shown = PhoneWindowOrder.display([w("a"), w("b"), w("c", pinned: true)],
                                             savedOrder: ["a", "b", "c"])
        XCTAssertEqual(shown.map(\.id), ["c", "a", "b"])
    }

    func test_twoPins_keepTheirRelativeOrder_andTheRestKeepTheirs() {
        let shown = PhoneWindowOrder.display([w("a", pinned: true), w("b"), w("c", pinned: true), w("d")],
                                             savedOrder: ["d", "c", "b", "a"])
        XCTAssertEqual(shown.map(\.id), ["c", "a", "d", "b"])
    }

    func test_noSavedOrder_stillFloatsPins() {
        let shown = PhoneWindowOrder.display([w("a"), w("b", pinned: true)], savedOrder: [])
        XCTAssertEqual(shown.map(\.id), ["b", "a"])
    }

    // MARK: Q-88 US-004 — Recent / Manual

    private func ids(_ mode: PhoneWindowOrder.Mode, _ windows: [WindowState],
                     saved: [String] = [], recency: [String] = []) -> [String] {
        PhoneWindowOrder.display(windows, mode: mode, savedOrder: saved, recency: recency).map(\.id)
    }

    func test_recent_mostRecentFirst_unknownIdsKeepTheMacsOrderAfter() {
        XCTAssertEqual(ids(.recent, [w("a"), w("b"), w("c"), w("d")], saved: ["a", "b", "c", "d"],
                           recency: ["c", "zz", "a"]),
                       ["c", "a", "b", "d"])
    }

    func test_manual_ignoresRecency() {
        XCTAssertEqual(ids(.manual, [w("a"), w("b"), w("c")], saved: ["b", "a"], recency: ["c"]),
                       ["b", "a", "c"])
    }

    func test_pinsFirstInBothModes() {
        let windows = [w("a"), w("b", pinned: true), w("c")]
        XCTAssertEqual(ids(.recent, windows, recency: ["c", "a"]), ["b", "c", "a"])
        XCTAssertEqual(ids(.manual, windows, saved: ["c", "a", "b"]), ["b", "c", "a"])
    }

    func test_recent_emptyStack_isTheMacsOrder() {
        XCTAssertEqual(ids(.recent, [w("a"), w("b")], saved: ["b", "a"]), ["a", "b"])
    }

    // Default for a phone that never chose a mode.

    func test_initialMode_neverConnected_isRecent() {
        XCTAssertEqual(PhoneWindowOrder.initialMode(savedOrder: [], macOrder: ["a", "b"]), .recent)
    }

    func test_initialMode_savedOrderIsJustTheMacsOrder_isRecent() {
        // Every layout appends to the saved order, so it is never empty for
        // someone who has connected. Closed and new windows do not count.
        XCTAssertEqual(PhoneWindowOrder.initialMode(savedOrder: ["a", "gone", "b"], macOrder: ["a", "new", "b"]),
                       .recent)
    }

    func test_initialMode_draggedOrder_staysManual() {
        XCTAssertEqual(PhoneWindowOrder.initialMode(savedOrder: ["b", "a"], macOrder: ["a", "b"]), .manual)
    }
}
