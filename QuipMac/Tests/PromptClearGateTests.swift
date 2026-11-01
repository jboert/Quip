import XCTest
@testable import Quip

/// Q-56 (6). An idle agent's CPU blips past the threshold every few seconds
/// (all idle Claude sessions at once, 2026-10-31), and one blip used to clear
/// the badge; the raise gate then put it back 3 s later. 10,486 raises in a
/// day, 62% of the "busy" spells the shortest the loop allows. A clear now
/// re-reads the pane: unchanged since the raise means nothing happened.
@MainActor
final class PromptClearGateTests: XCTestCase {

    func test_aPaneUnchangedSinceTheRaiseHoldsTheBadge() {
        XCTAssertEqual(
            PromptClearGate.decide(raised: "❯", now: "❯", capturedAt: 3, current: 3),
            .hold)
    }

    /// The owner answered, or the agent started its turn: the pane moved.
    func test_aPaneThatMovedClearsTheBadge() {
        XCTAssertEqual(
            PromptClearGate.decide(raised: "❯", now: "✶ Working… (1s)", capturedAt: 3, current: 3),
            .clear)
    }

    /// Without a reading to compare (raised on CPU alone, or the pane cannot
    /// be read now) the clear goes through as it always did: a stale badge
    /// is the failure the clear path must never add.
    func test_withNothingToCompareTheClearGoesThrough() {
        XCTAssertEqual(PromptClearGate.decide(raised: nil, now: "❯", capturedAt: 3, current: 3), .clear)
        XCTAssertEqual(PromptClearGate.decide(raised: "❯", now: nil, capturedAt: 3, current: 3), .clear)
    }

    /// The window was untracked, retracked or went to dictation meanwhile;
    /// this read speaks for none of them.
    func test_aStaleReadDoesNothing() {
        XCTAssertEqual(
            PromptClearGate.decide(raised: "❯", now: "✶ Working… (1s)", capturedAt: 3, current: 4),
            .ignore)
    }

    /// After a hold the next blip is not re-read at once, so a long noisy
    /// spell costs one `osascript` per cooldown, not one per poll.
    func test_aHoldPausesRechecksForTheCooldown() {
        let held = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(PromptClearGate.mayCheck(now: held.addingTimeInterval(1.9), heldAt: held))
        XCTAssertTrue(PromptClearGate.mayCheck(now: held.addingTimeInterval(PromptClearGate.cooldown), heldAt: held))
        XCTAssertTrue(PromptClearGate.mayCheck(now: held, heldAt: nil))
    }
}
