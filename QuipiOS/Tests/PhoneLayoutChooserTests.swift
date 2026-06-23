import XCTest
import CoreGraphics
@testable import Quip

/// Tests for the pure-function bits of phone-side window layout — the
/// auto-arrange chooser, the grid cell calculator, and the nearest-cell
/// finder used by drag-to-snap. Live in pure fns on `MainiOSView` so a
/// future refactor of the surrounding view code doesn't require setting
/// up SwiftUI environments to verify the math.
final class PhoneLayoutChooserTests: XCTestCase {

    // MARK: chooseAutoLayout

    func testChooserPicksHorizontalForOneWindow() {
        XCTAssertEqual(MainiOSView.chooseAutoLayout(count: 1), "horizontal")
    }

    func testChooserPicksHorizontalForTwoWindows() {
        XCTAssertEqual(MainiOSView.chooseAutoLayout(count: 2), "horizontal")
    }

    func testChooserPicksVerticalForThreeWindows() {
        XCTAssertEqual(MainiOSView.chooseAutoLayout(count: 3), "vertical")
    }

    func testChooserPicksGridForFourWindows() {
        XCTAssertEqual(MainiOSView.chooseAutoLayout(count: 4), "grid")
    }

    func testChooserPicksGridForSixWindows() {
        XCTAssertEqual(MainiOSView.chooseAutoLayout(count: 6), "grid")
    }

    func testChooserPicksGridForManyWindows() {
        XCTAssertEqual(MainiOSView.chooseAutoLayout(count: 10), "grid")
    }

    // MARK: gridFrame

    func testGridFrameHorizontalSplitsEvenly() {
        let total = 4
        for i in 0..<total {
            let f = MainiOSView.gridFrame(mode: "horizontal", index: i, total: total)!
            XCTAssertEqual(f.x, Double(i) * 0.25, accuracy: 1e-9)
            XCTAssertEqual(f.y, 0)
            XCTAssertEqual(f.width, 0.25, accuracy: 1e-9)
            XCTAssertEqual(f.height, 1.0)
        }
    }

    func testGridFrameVerticalSplitsEvenly() {
        let total = 3
        for i in 0..<total {
            let f = MainiOSView.gridFrame(mode: "vertical", index: i, total: total)!
            XCTAssertEqual(f.x, 0)
            XCTAssertEqual(f.y, Double(i) / 3.0, accuracy: 1e-9)
            XCTAssertEqual(f.width, 1.0)
            XCTAssertEqual(f.height, 1.0 / 3.0, accuracy: 1e-9)
        }
    }

    func testGridFrameUnknownModeReturnsNil() {
        XCTAssertNil(MainiOSView.gridFrame(mode: "diagonal", index: 0, total: 4))
    }

    // MARK: gridFrame — mode "grid" (Story 6, 2026-05-06)

    func testGridModeFourWindowsIsTwoByTwo() {
        // total=4 → cols=ceil(sqrt(4))=2, rows=ceil(4/2)=2 → 2×2 grid
        let frames = (0..<4).map { MainiOSView.gridFrame(mode: "grid", index: $0, total: 4)! }
        XCTAssertEqual(frames[0].x, 0.0,  accuracy: 1e-9); XCTAssertEqual(frames[0].y, 0.0, accuracy: 1e-9)
        XCTAssertEqual(frames[1].x, 0.5,  accuracy: 1e-9); XCTAssertEqual(frames[1].y, 0.0, accuracy: 1e-9)
        XCTAssertEqual(frames[2].x, 0.0,  accuracy: 1e-9); XCTAssertEqual(frames[2].y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(frames[3].x, 0.5,  accuracy: 1e-9); XCTAssertEqual(frames[3].y, 0.5, accuracy: 1e-9)
        for f in frames {
            XCTAssertEqual(f.width, 0.5,  accuracy: 1e-9)
            XCTAssertEqual(f.height, 0.5, accuracy: 1e-9)
        }
    }

    func testGridModeFiveWindowsIsThreeByTwoWithLeftover() {
        // total=5 → cols=ceil(sqrt(5))=3, rows=ceil(5/3)=2 → 3×2 with one empty cell
        let total = 5
        let frames = (0..<total).map { MainiOSView.gridFrame(mode: "grid", index: $0, total: total)! }
        XCTAssertEqual(frames[0].x, 0.0,        accuracy: 1e-9)
        XCTAssertEqual(frames[1].x, 1.0/3.0,    accuracy: 1e-9)
        XCTAssertEqual(frames[2].x, 2.0/3.0,    accuracy: 1e-9)
        XCTAssertEqual(frames[3].x, 0.0,        accuracy: 1e-9)
        XCTAssertEqual(frames[3].y, 0.5,        accuracy: 1e-9)
        XCTAssertEqual(frames[4].x, 1.0/3.0,    accuracy: 1e-9)
        for f in frames {
            XCTAssertEqual(f.width, 1.0/3.0, accuracy: 1e-9)
            XCTAssertEqual(f.height, 0.5,    accuracy: 1e-9)
        }
    }

    func testGridModeNineWindowsIsThreeByThree() {
        let total = 9
        let f = MainiOSView.gridFrame(mode: "grid", index: 8, total: total)!
        XCTAssertEqual(f.x, 2.0/3.0, accuracy: 1e-9)
        XCTAssertEqual(f.y, 2.0/3.0, accuracy: 1e-9)
        XCTAssertEqual(f.width, 1.0/3.0,  accuracy: 1e-9)
        XCTAssertEqual(f.height, 1.0/3.0, accuracy: 1e-9)
    }

    func testGridModeOneWindowFullScreen() {
        let f = MainiOSView.gridFrame(mode: "grid", index: 0, total: 1)!
        XCTAssertEqual(f.x, 0.0)
        XCTAssertEqual(f.y, 0.0)
        XCTAssertEqual(f.width, 1.0)
        XCTAssertEqual(f.height, 1.0)
    }

    func testGridFrameOutOfRangeReturnsNil() {
        XCTAssertNil(MainiOSView.gridFrame(mode: "horizontal", index: 5, total: 3))
        XCTAssertNil(MainiOSView.gridFrame(mode: "horizontal", index: -1, total: 3))
    }

    func testGridFrameEmptyTotalReturnsNil() {
        XCTAssertNil(MainiOSView.gridFrame(mode: "horizontal", index: 0, total: 0))
    }

    // MARK: nearestGridIndex

    func testNearestGridIndexHorizontalDropOnSecondCell() {
        // 4-cell horizontal grid: cell 1 center is at x=0.375, y=0.5.
        let drop = CGPoint(x: 0.4, y: 0.5)
        XCTAssertEqual(MainiOSView.nearestGridIndex(mode: "horizontal", total: 4, dropCenter: drop), 1)
    }

    func testNearestGridIndexVerticalDropOnLastCell() {
        // 3-cell vertical grid: cell 2 center is at x=0.5, y=0.833.
        let drop = CGPoint(x: 0.5, y: 0.85)
        XCTAssertEqual(MainiOSView.nearestGridIndex(mode: "vertical", total: 3, dropCenter: drop), 2)
    }

    func testNearestGridIndexClampsToFirstWhenDropInLeftEdge() {
        // 4-cell horizontal: cell 0 center at x=0.125. Drop at x=0 is closer
        // to cell 0 than cell 1 (x=0.375).
        let drop = CGPoint(x: 0, y: 0.5)
        XCTAssertEqual(MainiOSView.nearestGridIndex(mode: "horizontal", total: 4, dropCenter: drop), 0)
    }

    func testNearestGridIndexClampsToLastWhenDropInRightEdge() {
        let drop = CGPoint(x: 1.0, y: 0.5)
        XCTAssertEqual(MainiOSView.nearestGridIndex(mode: "horizontal", total: 4, dropCenter: drop), 3)
    }

    // MARK: nearestGridIndex — mode "grid"

    func testNearestGridIndexGridDropOnTopRightCell() {
        // total=4 → 2×2. Top-right cell (idx=1) center is at (0.75, 0.25).
        let drop = CGPoint(x: 0.8, y: 0.2)
        XCTAssertEqual(MainiOSView.nearestGridIndex(mode: "grid", total: 4, dropCenter: drop), 1)
    }

    func testNearestGridIndexGridDropOnBottomLeftCell() {
        // total=4 → 2×2. Bottom-left cell (idx=2) center is at (0.25, 0.75).
        let drop = CGPoint(x: 0.2, y: 0.8)
        XCTAssertEqual(MainiOSView.nearestGridIndex(mode: "grid", total: 4, dropCenter: drop), 2)
    }

    func testNearestGridIndexGridSixWindowsBottomRight() {
        // total=6 → 3 cols × 2 rows. Cell idx=5 center is at (5/6, 0.75).
        let drop = CGPoint(x: 0.85, y: 0.8)
        XCTAssertEqual(MainiOSView.nearestGridIndex(mode: "grid", total: 6, dropCenter: drop), 5)
    }

    // MARK: reorderedSequence — drag-reorder remove-then-insert clamp

    func testReorderMoveForwardLandsAtSlot() {
        XCTAssertEqual(
            MainiOSView.reorderedSequence(["A", "B", "C", "D"], moving: "A", toSlot: 2),
            ["B", "C", "A", "D"]
        )
    }

    func testReorderMoveBackwardLandsAtSlot() {
        XCTAssertEqual(
            MainiOSView.reorderedSequence(["A", "B", "C", "D"], moving: "D", toSlot: 1),
            ["A", "D", "B", "C"]
        )
    }

    func testReorderToSameSlotIsNoOp() {
        let input = ["A", "B", "C"]
        XCTAssertEqual(MainiOSView.reorderedSequence(input, moving: "B", toSlot: 1), input)
    }

    func testReorderAbsentIdIsNoOp() {
        let input = ["A", "B", "C"]
        XCTAssertEqual(MainiOSView.reorderedSequence(input, moving: "Z", toSlot: 0), input)
    }

    func testReorderSlotClampsAboveRange() {
        // Slot 99 clamps to last index → card lands at the end.
        XCTAssertEqual(
            MainiOSView.reorderedSequence(["A", "B", "C"], moving: "A", toSlot: 99),
            ["B", "C", "A"]
        )
    }

    func testReorderSlotClampsBelowRange() {
        // Negative slot clamps to 0 → card lands at the front.
        XCTAssertEqual(
            MainiOSView.reorderedSequence(["A", "B", "C"], moving: "C", toSlot: -5),
            ["C", "A", "B"]
        )
    }

    // MARK: reconciledWindowOrder — prune closed + append new

    func testReconcileAppendsNewWindowsAtEnd() {
        XCTAssertEqual(
            MainiOSView.reconciledWindowOrder(saved: ["A", "B"], active: ["A", "B", "C"]),
            ["A", "B", "C"]
        )
    }

    func testReconcilePrunesClosedWindows() {
        XCTAssertEqual(
            MainiOSView.reconciledWindowOrder(saved: ["A", "B", "C"], active: ["A", "C"]),
            ["A", "C"]
        )
    }

    func testReconcilePreservesSavedOrderAndAppendsNew() {
        // Survivors keep their saved (user-dragged) order; brand-new "D"
        // appends after, in incoming order — not interleaved.
        XCTAssertEqual(
            MainiOSView.reconciledWindowOrder(saved: ["C", "A", "B"], active: ["A", "B", "C", "D"]),
            ["C", "A", "B", "D"]
        )
    }

    func testReconcileEmptySavedReturnsActiveOrder() {
        XCTAssertEqual(
            MainiOSView.reconciledWindowOrder(saved: [], active: ["X", "Y"]),
            ["X", "Y"]
        )
    }

    func testReconcileAllClosedReturnsEmpty() {
        XCTAssertEqual(
            MainiOSView.reconciledWindowOrder(saved: ["A", "B"], active: []),
            []
        )
    }
}
