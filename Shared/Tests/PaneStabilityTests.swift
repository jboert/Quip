import XCTest
@testable import Quip

/// Q-21. `TerminalStateDetector` infers "waiting for input" from CPU alone, so
/// an agent blocked on an LLM stream or an MCP call — which burns ~0% CPU — is
/// indistinguishable from a prompt waiting on a human. Measured 2026-08-19:
/// 44 `neutral` ↔ `waiting_for_input` transitions in 180s for one window, every
/// raise clearing again 1-5s later, so none of them were prompts.
///
/// The gate is a second signal: capture the pane twice a few hundred ms apart
/// and only raise when the tail did not move. A working agent redraws a live
/// counter every frame; an idle one is frozen.
///
/// The fixtures below are real captures taken from live iTerm panes, not
/// invented — see the sample table in the Q-21 board entry.
final class PaneStabilityTests: XCTestCase {

    /// A finished turn sitting at its input box. Read three times a second
    /// apart during the Q-21 investigation, byte-identical every time.
    private let idlePane = """
        ⏺ Done. Four suites green.
        ✻ Cooked for 23m 34s · 2 shells still running
        ────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────
          nugget-expo main | █░░░ 🟢 18% | Opus | 🧠 high…
          ⏵⏵ auto mode on · 2 shells · ← 3 agents
        """

    func testIdenticalCapturesAreStable() {
        XCTAssertTrue(PaneStability.isStable(idlePane, idlePane))
    }

    /// The working case. Same pane, same input box, but the elapsed counter in
    /// the status line advances between reads. This is the whole point of the
    /// gate: the input box `❯` is drawn in BOTH states, so its presence proves
    /// nothing — only the movement does.
    func testAdvancingWorkCounterIsNotStable() {
        let first = """
            ⏺ Reading the detector.
            ✶ Crystallizing… (40s · ↓ 1.4k tokens)
            ────────────────────────────────────────────
            ❯
            """
        let second = """
            ⏺ Reading the detector.
            ✶ Crystallizing… (41s · ↓ 1.6k tokens)
            ────────────────────────────────────────────
            ❯
            """
        XCTAssertFalse(PaneStability.isStable(first, second))
    }

    /// A repaint that only changes colour must not read as work. Terminals
    /// re-emit SGR sequences for all sorts of reasons that have nothing to do
    /// with an agent running, and treating those as movement would keep the
    /// badge from ever firing.
    func testColourOnlyRepaintIsStable() {
        let plain = "❯ 1. Yes\n  2. No"
        let coloured = "\u{1B}[32m❯ 1. Yes\u{1B}[0m\n  2. No"
        XCTAssertTrue(PaneStability.isStable(plain, coloured))
    }

    /// Output scrolling past the viewport between the two reads is movement,
    /// not something to look past: `readContent` returns the visible screen, so
    /// if the top lines changed, the pane emitted output in the last few
    /// hundred milliseconds and the agent is working.
    func testScrolledOutputIsNotStable() {
        let older = (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n" + idlePane
        let newer = (11...50).map { "line \($0)" }.joined(separator: "\n") + "\n" + idlePane
        XCTAssertFalse(PaneStability.isStable(older, newer))
    }

    /// Trailing whitespace churns as a terminal pads redrawn rows, so it must
    /// not count as movement on its own.
    func testTrailingWhitespaceIsIgnored() {
        XCTAssertTrue(PaneStability.isStable("❯", "❯   "))
    }

    /// Real content movement inside the tail must still register even without a
    /// counter — an agent streaming prose is working.
    func testNewOutputInTheTailIsNotStable() {
        let before = "❯\n⏺ Thinking about it."
        let after = "❯\n⏺ Thinking about it. Here is the answer."
        XCTAssertFalse(PaneStability.isStable(before, after))
    }

    /// An empty read is not evidence of quiet. `readContent` returns empty when
    /// the AppleScript failed or the window had no session, and treating two
    /// failures as "stable" would raise the badge on exactly the windows the
    /// gate could not see. Those callers fail open through a separate path that
    /// logs; the predicate itself must refuse to answer.
    func testEmptyCapturesAreNotStable() {
        XCTAssertFalse(PaneStability.isStable("", ""))
        XCTAssertFalse(PaneStability.isStable("", idlePane))
    }
}
