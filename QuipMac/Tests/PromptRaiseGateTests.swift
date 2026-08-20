import XCTest
@testable import Quip

/// Q-21. Raising `waitingForInput` is the expensive direction — it badges the
/// phone grid and can push "an agent is asking you something". Q-20 made that
/// direction wait for 1.5s of sustained CPU quiet, which did not help, because
/// an agent blocked on an LLM stream is exactly as quiet as a prompt.
///
/// This is the decision the detector makes once the debounce has approved a
/// raise and a pane re-read has come back. The read itself is IO on a
/// background queue; everything that decides an outcome lives here so it can be
/// tested without spawning `osascript`.
@MainActor
final class PromptRaiseGateTests: XCTestCase {

    func test_aFrozenPaneRaisesTheBadge() {
        XCTAssertEqual(
            PromptRaiseGate.decide(stability: .stable, capturedAt: 7, current: 7),
            .raise)
    }

    /// The Q-21 case. CPU said quiet, the debounce agreed for 1.5s, but the
    /// pane is still redrawing a live counter — the agent is mid-turn and the
    /// phone must not be told a human is wanted.
    func test_aMovingPaneDropsTheRaise() {
        XCTAssertEqual(
            PromptRaiseGate.decide(stability: .moving, capturedAt: 7, current: 7),
            .drop)
    }

    /// Fail OPEN, deliberately. An unreadable pane means a missing Automation
    /// grant or a terminal that will not answer AppleScript; refusing to raise
    /// there would silently stop badging real prompts and look like a fix. The
    /// old CPU-only behaviour is the documented, logged fallback instead.
    func test_anUnreadablePaneStillRaises() {
        XCTAssertEqual(
            PromptRaiseGate.decide(stability: .unreadable, capturedAt: 7, current: 7),
            .raise)
    }

    /// The pane read is asynchronous, so the window can be untracked, retracked
    /// or switched to STT while it is in flight. Q-16b established the
    /// generation counter for exactly this; a confirmation that outlived its
    /// generation describes a window that no longer exists.
    func test_aConfirmationFromAnEarlierGenerationIsDropped() {
        XCTAssertEqual(
            PromptRaiseGate.decide(stability: .stable, capturedAt: 6, current: 7),
            .drop)
    }

    /// Staleness outranks fail-open: an unreadable result from a dead
    /// generation must not resurrect a raise for a window that was retracked.
    func test_stalenessBeatsFailOpen() {
        XCTAssertEqual(
            PromptRaiseGate.decide(stability: .unreadable, capturedAt: 6, current: 7),
            .drop)
    }

    /// The measured Q-21 shape, end to end through the two pieces: CPU quiet
    /// for the full debounce run, but the pane moving every time it is read.
    /// Baseline behaviour raised 22 times in three minutes; this must raise
    /// zero. `TerminalStateDebounce` is replayed alongside the gate so the test
    /// fails if either half regresses.
    func test_aNetworkBlockedAgentNeverRaises() {
        var debounce = TerminalStateDebounce()
        let window = "com.googlecode.iterm2.114"
        var raises = 0

        for tick in 0..<720 {
            guard debounce.observe(windowId: window, detected: .waitingForInput, current: .neutral)
            else { continue }
            // The pane is re-read only when the debounce approves, and the
            // agent is streaming, so the two captures never match.
            let moving = PaneStability.isStable(
                "✶ Crystallizing… (\(tick)s · ↓ 1.4k tokens)\n❯",
                "✶ Crystallizing… (\(tick + 1)s · ↓ 1.6k tokens)\n❯")
            let outcome = PromptRaiseGate.decide(
                stability: moving ? .stable : .moving, capturedAt: 1, current: 1)
            if outcome == .raise { raises += 1 }
        }

        XCTAssertEqual(raises, 0, "a working agent must never badge the phone")
    }

    /// The other half of the same oracle: a real prompt still lands. A frozen
    /// pane plus a sustained quiet run has to produce exactly one raise, or the
    /// gate has traded the flap for a dead feature.
    func test_aRealPromptStillRaisesExactlyOnce() {
        var debounce = TerminalStateDebounce()
        let window = "com.googlecode.iterm2.114"
        let idle = "✻ Cooked for 23m 34s · 2 shells still running\n❯"
        var raises = 0
        var state: TerminalState = .neutral

        for _ in 0..<40 {
            guard debounce.observe(windowId: window, detected: .waitingForInput, current: state)
            else { continue }
            let outcome = PromptRaiseGate.decide(
                stability: PaneStability.isStable(idle, idle) ? .stable : .moving,
                capturedAt: 1, current: 1)
            if outcome == .raise {
                raises += 1
                state = .waitingForInput
            }
        }

        XCTAssertEqual(raises, 1)
    }
}
