// WindowScreenOrderTests.swift
// Shared tests — the sidebar lists windows the way the desk looks

import XCTest
@testable import Quip

final class WindowScreenOrderTests: XCTestCase {

    private func item(_ id: String, tier: Int = 0, x: Double, y: Double,
                      height: Double = 800,
                      displayX: Double = 0, displayY: Double = 0) -> WindowScreenOrder.Item {
        WindowScreenOrder.Item(id: id, tier: tier, displayX: displayX, displayY: displayY,
                               x: x, y: y, height: height)
    }

    /// The desk this was asked for: three terminals side by side read left to
    /// right, whatever order CoreGraphics hands them back in (front-to-back,
    /// i.e. by last focus).
    func testSideBySideWindowsReadLeftToRight() {
        let order = WindowScreenOrder.order([
            item("right", x: 2400, y: 40),
            item("left", x: 0, y: 40),
            item("middle", x: 1200, y: 40),
        ])
        XCTAssertEqual(order, ["left", "middle", "right"])
    }

    /// Stacked windows read top to bottom.
    func testStackedWindowsReadTopToBottom() {
        let order = WindowScreenOrder.order([
            item("bottom", x: 0, y: 900, height: 400),
            item("top", x: 0, y: 0, height: 400),
        ])
        XCTAssertEqual(order, ["top", "bottom"])
    }

    /// A tiled desk is rows of columns: both windows of the top row come before
    /// either window of the bottom row.
    func testRowsBeforeColumns() {
        let order = WindowScreenOrder.order([
            item("bottom-right", x: 1200, y: 800, height: 700),
            item("top-right", x: 1200, y: 0, height: 700),
            item("bottom-left", x: 0, y: 800, height: 700),
            item("top-left", x: 0, y: 0, height: 700),
        ])
        XCTAssertEqual(order, ["top-left", "top-right", "bottom-left", "bottom-right"])
    }

    /// Two windows in the same visual row are never pixel-aligned. Within half
    /// the first window's height they still count as one row, so a 12px offset
    /// does not interleave the columns of a tiled desk.
    func testNearlyAlignedWindowsCountAsOneRow() {
        let order = WindowScreenOrder.order([
            item("right", x: 1200, y: 12, height: 900),
            item("left", x: 0, y: 0, height: 900),
        ])
        XCTAssertEqual(order, ["left", "right"])
    }

    /// Far enough down and it is a new row, even in the same column region.
    func testAWindowBelowTheToleranceStartsANewRow() {
        let order = WindowScreenOrder.order([
            item("below", x: 0, y: 500, height: 400),
            item("above", x: 600, y: 0, height: 400),
        ])
        XCTAssertEqual(order, ["above", "below"])
    }

    /// "Focus on terminal windows first": tier beats position, so a terminal in
    /// the bottom-right corner still outranks a browser at the top left.
    func testTerminalsComeFirstWhereverTheySit() {
        let order = WindowScreenOrder.order([
            item("browser", tier: 2, x: 0, y: 0),
            item("terminal", tier: 0, x: 3000, y: 1200),
            item("simulator", tier: 1, x: 100, y: 100),
        ])
        XCTAssertEqual(order, ["terminal", "simulator", "browser"])
    }

    /// Windows group by monitor before they order within one: the left
    /// display's windows all come before the right display's.
    func testDisplaysGroupLeftToRight() {
        let order = WindowScreenOrder.order([
            item("right-display-left-window", x: 3440, y: 0, displayX: 3440),
            item("left-display-right-window", x: 1700, y: 0, displayX: 0),
            item("left-display-left-window", x: 0, y: 0, displayX: 0),
        ])
        XCTAssertEqual(order, ["left-display-left-window",
                               "left-display-right-window",
                               "right-display-left-window"])
    }

    /// Two windows at the same spot (a sheet over its parent, a window not yet
    /// placed) must not swap between snapshots — that is the churn this whole
    /// list is supposed to stop.
    func testIdenticalPositionsAreOrderedStablyByID() {
        let a = WindowScreenOrder.order([item("b", x: 0, y: 0), item("a", x: 0, y: 0)])
        let b = WindowScreenOrder.order([item("a", x: 0, y: 0), item("b", x: 0, y: 0)])
        XCTAssertEqual(a, ["a", "b"])
        XCTAssertEqual(a, b)
    }

    func testEmptyInputIsEmptyOutput() {
        XCTAssertEqual(WindowScreenOrder.order([]), [])
    }
}
