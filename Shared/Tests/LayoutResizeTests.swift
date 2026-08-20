#if os(macOS)
import XCTest
@testable import Quip

final class LayoutResizeTests: XCTestCase {

    private let half = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)

    private func assertRect(_ r: NormalizedRect, _ x: Double, _ y: Double,
                            _ w: Double, _ h: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.x, x, accuracy: 0.0001, "x", file: file, line: line)
        XCTAssertEqual(r.y, y, accuracy: 0.0001, "y", file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: 0.0001, "width", file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: 0.0001, "height", file: file, line: line)
    }

    // MARK: - Basic edges

    func testTrailingEdgeGrowsWidthOnly() {
        let r = LayoutResize.resize(half, handle: .trailing, deltaX: 0.25, deltaY: 0)
        assertRect(r, 0, 0, 0.75, 1)
    }

    func testLeadingEdgeMovesOriginAndShrinksWidth() {
        let r = LayoutResize.resize(half, handle: .leading, deltaX: 0.2, deltaY: 0)
        assertRect(r, 0.2, 0, 0.3, 1)
    }

    func testBottomEdgeIgnoresHorizontalDrag() {
        let r = LayoutResize.resize(half, handle: .bottom, deltaX: 0.4, deltaY: -0.3)
        assertRect(r, 0, 0, 0.5, 0.7)
    }

    func testCornerMovesBothAxes() {
        let r = LayoutResize.resize(half, handle: .bottomTrailing, deltaX: 0.25, deltaY: -0.4)
        assertRect(r, 0, 0, 0.75, 0.6)
    }

    // MARK: - Clamping

    func testCannotDragPastTheDisplayEdge() {
        let r = LayoutResize.resize(half, handle: .trailing, deltaX: 5, deltaY: 0)
        assertRect(r, 0, 0, 1, 1)
    }

    func testCannotInvertTheRect() {
        let r = LayoutResize.resize(half, handle: .leading, deltaX: 0.9, deltaY: 0)
        assertRect(r, 0.5 - LayoutResize.minimumSide, 0, LayoutResize.minimumSide, 1)
        XCTAssertGreaterThan(r.width, 0, "A rect must never invert into negative width")
    }

    func testMinimumSizeIsEnforcedOnBothAxes() {
        let tile = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let r = LayoutResize.resize(tile, handle: .bottomTrailing, deltaX: -1, deltaY: -1)
        assertRect(r, 0.25, 0.25, LayoutResize.minimumSide, LayoutResize.minimumSide)
    }

    func testZeroDragIsIdentity() {
        for handle in LayoutResize.Handle.allCases {
            let r = LayoutResize.resize(half, handle: handle, deltaX: 0, deltaY: 0)
            assertRect(r, 0, 0, 0.5, 1)
        }
    }

    // MARK: - clampToDisplay

    func testClampPullsAnOutOfBoundsRectBackInside() {
        let stray = NormalizedRect(x: 0.9, y: -0.2, width: 0.5, height: 0.5)
        let r = LayoutResize.clampToDisplay(stray)
        assertRect(r, 0.5, 0, 0.5, 0.5)
    }

    func testClampRaisesADegenerateRectToTheMinimum() {
        let flat = NormalizedRect(x: 0.1, y: 0.1, width: 0, height: 0)
        let r = LayoutResize.clampToDisplay(flat)
        XCTAssertEqual(r.width, LayoutResize.minimumSide, accuracy: 0.0001)
        XCTAssertEqual(r.height, LayoutResize.minimumSide, accuracy: 0.0001)
    }

    func testClampLeavesAValidRectAlone() {
        let ok = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let r = LayoutResize.clampToDisplay(ok)
        assertRect(r, 0.25, 0.25, 0.5, 0.5)
    }
}
#endif
