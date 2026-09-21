import Foundation

/// Whether a poll result that was computed off-main is still describing the
/// world it will be written into.
///
/// `TerminalStateDetector` snapshots MainActor state, runs `ps` work on
/// `pollQueue`, then hops back to main to apply. Everything can move in
/// between: a window gets untracked, a shell respawns under a new PID,
/// monitoring stops. The result landed anyway — reviving state for a window the
/// UI had dropped, and reinstalling kqueue sources immediately after
/// `stopMonitoring` cancelled them.
///
/// Pure so the rule is testable without spawning a single process; the detector
/// itself is not injectable without a broad refactor the plan explicitly rules
/// out.
enum TerminalPollGate {

    /// May this per-window poll result be applied?
    ///
    /// - Parameters:
    ///   - capturedGeneration: monitoring generation when the poll started.
    ///   - currentGeneration: generation now. `startMonitoring`/`stopMonitoring`
    ///     bump it, so a mismatch means the run this result belongs to is over.
    ///   - capturedPid: shell PID the poll measured.
    ///   - currentPid: shell PID tracked now, or nil if the window was
    ///     untracked while the poll ran.
    ///   - resolvedPid: PID this same poll re-resolved after detecting a TTY
    ///     respawn, if any. This is the sole reason a PID mismatch is
    ///     acceptable — the mismatch is the result's own doing, and rejecting it
    ///     would quietly disable respawn recovery.
    static func shouldApply(
        capturedGeneration: Int,
        currentGeneration: Int,
        capturedPid: pid_t,
        currentPid: pid_t?,
        resolvedPid: pid_t?
    ) -> Bool {
        guard capturedGeneration == currentGeneration else { return false }
        guard let currentPid else { return false }
        if currentPid == capturedPid { return true }
        return resolvedPid == currentPid
    }
}

/// One-poll-at-a-time gate for the 0.25s timer.
///
/// A poll forks `ps`, which can outlast the interval. Without this the timer
/// keeps queueing work onto the serial poll queue and every backed-up item
/// forks again when it finally runs — pressure that only ever grows, and the
/// shape behind the main-thread hang reports.
///
/// Dropping a tick costs nothing: the next one re-reads the whole world, and
/// state transitions need two agreeing polls anyway.
///
/// Confined to the main actor because the timer fires there — no locking, and
/// no cross-actor state to reason about.
@MainActor
final class PollCoalescer {
    private var running = false

    /// Claim the slot. False means a poll is already in flight and this tick
    /// should be dropped rather than queued.
    func begin() -> Bool {
        guard !running else { return false }
        running = true
        return true
    }

    /// Release the slot. Idempotent — an extra call must not open a second
    /// slot, since exactly one `end` is owed per `begin` that returned true.
    func end() {
        running = false
    }
}
