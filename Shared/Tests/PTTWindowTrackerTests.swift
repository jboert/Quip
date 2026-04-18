import XCTest
@testable import Quip

/// Regression: voice-to-text sometimes landed in a different terminal than the
/// one highlighted when the user pressed PTT. Root cause was re-reading
/// `selectedWindowId` at release time — if a Mac-pushed `select_window` or a
/// layout-update-driven reassignment fired during recording, `stopRecording`
/// would send the transcription to the new selection, not the one the mic was
/// started against. The tracker pins the windowId at `begin(...)` time.
final class PTTWindowTrackerTests: XCTestCase {

    func testEndReturnsWindowIdCapturedAtBegin() {
        var tracker = PTTWindowTracker()
        tracker.begin(windowId: "win-A")
        XCTAssertEqual(tracker.end(), "win-A")
    }

    func testEndReturnsNilAfterClearing() {
        var tracker = PTTWindowTracker()
        tracker.begin(windowId: "win-A")
        _ = tracker.end()
        XCTAssertNil(tracker.end(),
                     "Once end() has consumed the captured id, subsequent end() calls must return nil")
    }

    func testEndReturnsNilWhenNeverBegun() {
        var tracker = PTTWindowTracker()
        XCTAssertNil(tracker.end())
    }

    func testIntermediateSelectionChangeDoesNotAffectCapturedId() {
        // Simulates: user presses PTT while "win-A" is selected, then the Mac
        // pushes select_window("win-B") mid-recording. The transcription must
        // still go to "win-A" — the window the user was looking at when they
        // pressed the button.
        var tracker = PTTWindowTracker()
        tracker.begin(windowId: "win-A")
        // A mid-recording selection change is represented in QuipApp by
        // selectedWindowId changing — the tracker is deliberately unaware of
        // that, and that's the whole point.
        XCTAssertEqual(tracker.end(), "win-A")
    }

    func testIsActiveReflectsLifecycle() {
        var tracker = PTTWindowTracker()
        XCTAssertFalse(tracker.isActive)
        tracker.begin(windowId: "win-A")
        XCTAssertTrue(tracker.isActive)
        _ = tracker.end()
        XCTAssertFalse(tracker.isActive)
    }
}
