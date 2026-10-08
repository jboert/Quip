// WindowPinOrderTests.swift
// Shared tests — a pin survives every re-sort

import XCTest
@testable import Quip

final class WindowPinOrderTests: XCTestCase {

    func testNoPinsLeavesTheOrderExactlyAsItWas() {
        XCTAssertEqual(WindowPinOrder.apply(["a", "b", "c"], pinned: []), ["a", "b", "c"])
    }

    func testAPinnedWindowMovesToTheFront() {
        XCTAssertEqual(WindowPinOrder.apply(["a", "b", "c"], pinned: ["c"]), ["c", "a", "b"])
    }

    /// A pin is not a placement: two pinned windows keep the order the sort
    /// gave them, they do not reorder by when they were pinned.
    func testPinnedWindowsKeepTheirRelativeOrder() {
        XCTAssertEqual(WindowPinOrder.apply(["a", "b", "c", "d"], pinned: ["d", "b"]),
                       ["b", "d", "a", "c"])
    }

    /// A new pin lands after the pins already there, like a browser tab:
    /// first pinned stays first, the newest pin is the last of the group.
    func testANewPinGoesToTheEndOfThePinnedGroup() {
        XCTAssertEqual(WindowPinOrder.placingNewPin("d", in: ["a", "b", "c", "d"], pinned: []),
                       ["d", "a", "b", "c"], "no pins yet: straight to the front")
        XCTAssertEqual(WindowPinOrder.placingNewPin("a", in: ["c", "a", "b", "d"], pinned: ["c"]),
                       ["c", "a", "b", "d"], "already right after the pin: unchanged")
        XCTAssertEqual(WindowPinOrder.placingNewPin("a", in: ["a", "c", "b", "d"], pinned: ["c"]),
                       ["c", "a", "b", "d"], "a window above an existing pin lines up after it")
        XCTAssertEqual(WindowPinOrder.placingNewPin("x", in: ["a", "b"], pinned: ["a"]),
                       ["a", "b"], "an id that is not in the list changes nothing")
    }

    func testUnpinnedWindowsKeepTheirRelativeOrder() {
        XCTAssertEqual(WindowPinOrder.apply(["a", "b", "c", "d"], pinned: ["b"]),
                       ["b", "a", "c", "d"])
    }

    /// A pin for a window that is not in this list (closed, or on a Mac that
    /// has not seen it yet) is ignored rather than inventing a row.
    func testPinsForAbsentWindowsAreIgnored() {
        XCTAssertEqual(WindowPinOrder.apply(["a", "b"], pinned: ["ghost"]), ["a", "b"])
    }

    func testEverythingPinnedIsTheSameOrder() {
        XCTAssertEqual(WindowPinOrder.apply(["a", "b"], pinned: ["a", "b"]), ["a", "b"])
    }

    /// Pruning is explicit, because the default has to be that a pin outlives a
    /// window being closed for a moment.
    func testForgetKeepsOnlyLiveWindows() {
        XCTAssertEqual(WindowPinOrder.forget(["a", "b", "ghost"], keeping: ["a", "b", "c"]),
                       ["a", "b"])
    }
}
