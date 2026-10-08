import SwiftUI
import XCTest
@testable import Quip

/// The sidebar row's pin and move glyphs only show on hover, so the context
/// menu is the pointer-free way to reach them; and every layout animation must
/// stand down under Reduce Motion.
final class WindowRowMenuTests: XCTestCase {

    func test_unpinnedRowWithBothMoves_offersPinThenUpThenDown() {
        XCTAssertEqual(
            WindowRowMenu.actions(isPinned: false, canMoveUp: true, canMoveDown: true),
            ["Pin to top", "Move Up", "Move Down"]
        )
    }

    func test_pinnedRowWithNoNeighbours_offersOnlyUnpin() {
        XCTAssertEqual(
            WindowRowMenu.actions(isPinned: true, canMoveUp: false, canMoveDown: false),
            ["Unpin from top"]
        )
    }

    func test_reduceMotion_dropsTheAnimation() {
        XCTAssertNil(MotionPolicy.animation(.easeOut, reduceMotion: true))
    }

    func test_withoutReduceMotion_keepsTheAnimation() {
        XCTAssertNotNil(MotionPolicy.animation(.easeOut, reduceMotion: false))
    }
}
