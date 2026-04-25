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

    func testChooserPicksVerticalForManyWindows() {
        XCTAssertEqual(MainiOSView.chooseAutoLayout(count: 10), "vertical")
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
}
