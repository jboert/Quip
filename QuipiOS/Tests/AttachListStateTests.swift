import XCTest
@testable import Quip

/// US-006: a window attached from this phone reads "Attached" before the
/// Mac's scan catches up, and never after the window is gone.
final class AttachListStateTests: XCTestCase {

    private func window(_ sessionId: String, tracked: Bool = false) -> ITermWindowInfo {
        ITermWindowInfo(windowNumber: 1, title: sessionId, sessionId: sessionId,
                        cwd: "/tmp", isAlreadyTracked: tracked, isMiniaturized: false)
    }

    func test_isAttached_trueForTrackedOrRecentlyAttached() {
        XCTAssertTrue(AttachListState.isAttached(window("a", tracked: true), recent: []))
        XCTAssertTrue(AttachListState.isAttached(window("b"), recent: ["b"]))
        XCTAssertFalse(AttachListState.isAttached(window("c"), recent: ["b"]))
    }

    func test_pruned_keepsAnIdTheScanStillListsAsUntracked() {
        // The Mac has not caught up yet: the row must still read "Attached".
        let kept = AttachListState.pruned(["b"], afterScan: [window("a"), window("b")])
        XCTAssertEqual(kept, ["b"])
    }

    func test_pruned_dropsAnIdOnceTheMacReportsItTracked() {
        let kept = AttachListState.pruned(["b"], afterScan: [window("b", tracked: true)])
        XCTAssertTrue(kept.isEmpty)
    }

    func test_pruned_dropsAnIdTheScanNoLongerLists() {
        // The window was closed on the Mac: no stuck "Attached" row for it.
        let kept = AttachListState.pruned(["b", "c"], afterScan: [window("c")])
        XCTAssertEqual(kept, ["c"])
    }
}
