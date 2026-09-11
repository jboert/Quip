import XCTest
@testable import Quip

/// The three-way split between "could not look", "looked and it was empty",
/// and "there was nothing to look at".
///
/// `readContent` separates an AppleScript failure (nil) from an empty buffer
/// (""), and `waitForStableContent` used to collapse both with `?? ""`. Every
/// one of those cases then produced the same line — `TTS DROPPED … suspect a
/// revoked Automation/Accessibility grant` — which is an actively misleading
/// diagnosis: the 2026-09-11 burst that logged it for windows 246, 247 and 808
/// in the same second was the session-unmapping bug, not permissions.
final class ContentSettleOutcomeTests: XCTestCase {

    func testNonEmptyContentIsStableRegardlessOfEarlierFailures() {
        // A read that failed early and succeeded later still yields content.
        XCTAssertEqual(
            ContentSettleOutcome.atDeadline(finalContent: "hello", anyReadSucceeded: true),
            .stable("hello"))
    }

    /// The case the `?? ""` collapse destroyed: reads worked, the buffer was
    /// genuinely empty. The agent stayed quiet; nothing is broken.
    func testSuccessfulReadOfAnEmptyBufferIsEmptyNotUnreadable() {
        XCTAssertEqual(
            ContentSettleOutcome.atDeadline(finalContent: "", anyReadSucceeded: true),
            .empty)
    }

    /// No read ever succeeded — we could not look. This is the only case that
    /// should point a reader at Automation/Accessibility grants.
    func testNoSuccessfulReadIsUnreadable() {
        XCTAssertEqual(
            ContentSettleOutcome.atDeadline(finalContent: "", anyReadSucceeded: false),
            .unreadable)
    }

    /// `.empty` and `.unreadable` must never be equal — the whole point is that
    /// they route a debugger to different places.
    func testEmptyAndUnreadableAreDistinct() {
        XCTAssertNotEqual(
            ContentSettleOutcome.atDeadline(finalContent: "", anyReadSucceeded: true),
            ContentSettleOutcome.atDeadline(finalContent: "", anyReadSucceeded: false))
    }

    /// Content that is only whitespace is still content: `atDeadline` must not
    /// start trimming, because `readContent` already dropped trailing blank
    /// lines and a second opinion here would diverge from what the phone saw.
    /// The case the sentinel exists for: the iTerm2 read script ran fine but the
    /// session id we hold is not in its session tree any more. Reads did NOT
    /// succeed, and the old walk-miss `return ""` made this arrive as `.empty` —
    /// "the agent had nothing to say" about a window we could not read at all.
    func testSessionGoneIsNotEmptyAndNotUnreadable() {
        XCTAssertEqual(
            ContentSettleOutcome.atDeadline(finalContent: "", anyReadSucceeded: false,
                                            sessionGone: true),
            .sessionGone)
    }

    /// A session that came back mid-window (a self-heal landed between polls)
    /// must not be reported gone — only the last read decides, and content wins
    /// over every failure signal.
    func testContentWinsOverAStaleSessionGoneSignal() {
        XCTAssertEqual(
            ContentSettleOutcome.atDeadline(finalContent: "hello", anyReadSucceeded: true,
                                            sessionGone: true),
            .stable("hello"))
    }

    /// `sessionGone` is the more specific diagnosis and outranks `unreadable`:
    /// one names the session map, the other sends the reader to System Settings.
    func testSessionGoneOutranksUnreadable() {
        XCTAssertNotEqual(
            ContentSettleOutcome.atDeadline(finalContent: "", anyReadSucceeded: false,
                                            sessionGone: true),
            ContentSettleOutcome.atDeadline(finalContent: "", anyReadSucceeded: false))
    }

    func testWhitespaceOnlyContentCountsAsStable() {
        XCTAssertEqual(
            ContentSettleOutcome.atDeadline(finalContent: " ", anyReadSucceeded: true),
            .stable(" "))
    }
}
