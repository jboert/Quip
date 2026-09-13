import XCTest
@testable import Quip

/// Iteration 3 of the review hardening loop: a poll that started before the
/// world changed must not be allowed to write its answer into the world after.
///
/// The detector snapshots MainActor state, does `ps` work on `pollQueue`, then
/// hops back to main to apply. Between those two points a window can be
/// untracked, its shell can respawn under a new PID, or monitoring can stop
/// entirely — and the result still landed, resurrecting state for a window
/// nobody is watching and reinstalling kqueue sources that `stopMonitoring`
/// had just cancelled.
@MainActor
final class TerminalPollGateTests: XCTestCase {

    // MARK: - Generation

    /// The ordinary case: nothing changed while the poll ran.
    func test_appliesWhenGenerationAndPidAreUnchanged() {
        XCTAssertTrue(TerminalPollGate.shouldApply(
            capturedGeneration: 7, currentGeneration: 7,
            capturedPid: 42, currentPid: 42, resolvedPid: nil))
    }

    /// `stopMonitoring` bumps the generation, so a poll already in flight is
    /// invalidated wholesale. Without this the stop is not a stop: the queued
    /// result still reinstalls process sources on its way through main.
    func test_discardsResultFromAnEarlierGeneration() {
        XCTAssertFalse(TerminalPollGate.shouldApply(
            capturedGeneration: 7, currentGeneration: 8,
            capturedPid: 42, currentPid: 42, resolvedPid: nil))
    }

    // MARK: - Tracking

    /// Window untracked mid-poll — `currentPid` is nil because the entry is
    /// gone. Applying would resurrect state for a window the UI has dropped.
    func test_discardsResultForAnUntrackedWindow() {
        XCTAssertFalse(TerminalPollGate.shouldApply(
            capturedGeneration: 1, currentGeneration: 1,
            capturedPid: 42, currentPid: nil, resolvedPid: nil))
    }

    /// The shell respawned under a new PID while the poll was running, so this
    /// result describes a process that is gone. Someone else's answer.
    func test_discardsResultWhenThePidChangedUnderneath() {
        XCTAssertFalse(TerminalPollGate.shouldApply(
            capturedGeneration: 1, currentGeneration: 1,
            capturedPid: 42, currentPid: 99, resolvedPid: nil))
    }

    /// ...unless the poll is the thing that changed it. A TTY respawn is
    /// detected during the poll and applied as a `pidUpdate` before results,
    /// so the "mismatch" is this result's own work and must be honoured — this
    /// is the one exception, and getting it wrong would silently disable
    /// respawn recovery.
    func test_appliesWhenThePollItselfResolvedTheNewPid() {
        XCTAssertTrue(TerminalPollGate.shouldApply(
            capturedGeneration: 1, currentGeneration: 1,
            capturedPid: 42, currentPid: 99, resolvedPid: 99))
    }

    /// A resolved PID that still doesn't match what's tracked is not a licence
    /// to apply — something else moved it again.
    func test_discardsWhenResolvedPidAlsoDisagreesWithTracking() {
        XCTAssertFalse(TerminalPollGate.shouldApply(
            capturedGeneration: 1, currentGeneration: 1,
            capturedPid: 42, currentPid: 77, resolvedPid: 99))
    }

    // MARK: - Coalescing

    /// The timer fires every 0.25s but a poll spawns `ps` and can take longer.
    /// Without a gate the work items stack up on the serial queue and every
    /// one of them forks — the backpressure failure the hang investigation
    /// kept circling.
    func test_secondPollIsDroppedWhileTheFirstIsStillRunning() {
        let coalescer = PollCoalescer()
        XCTAssertTrue(coalescer.begin(), "first tick runs")
        XCTAssertFalse(coalescer.begin(), "second tick must be dropped, not queued")
    }

    func test_pollRunsAgainOnceThePreviousOneFinishes() {
        let coalescer = PollCoalescer()
        XCTAssertTrue(coalescer.begin())
        coalescer.end()
        XCTAssertTrue(coalescer.begin(), "a finished poll must not block the next tick")
    }

    /// Dropped ticks must not leave the gate stuck closed — `end()` is called
    /// once per poll that actually began, and an unbalanced end must be inert
    /// rather than opening a second slot.
    func test_endIsIdempotent() {
        let coalescer = PollCoalescer()
        XCTAssertTrue(coalescer.begin())
        coalescer.end()
        coalescer.end()
        XCTAssertTrue(coalescer.begin())
        XCTAssertFalse(coalescer.begin())
    }
}
