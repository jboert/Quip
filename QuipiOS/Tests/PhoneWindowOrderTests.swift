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
}
