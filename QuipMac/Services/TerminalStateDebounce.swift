import Foundation

/// How many agreeing polls a terminal state has to survive before it is allowed
/// to become the window's state.
///
/// This used to be one number (2 polls, ~0.5s) for every transition, and that
/// number was measured wrong on 2026-08-18: `push.log` recorded 73
/// `neutral` ↔ `waiting_for_input` transitions in 2m50s for a single busy iTerm
/// window — about 26 a minute. A working agent's CPU use oscillates across
/// `cpuIdleThreshold`, and half a second of quiet inside a working turn is
/// ordinary, not a prompt waiting for a human.
///
/// The two directions are not symmetric, so they no longer share a threshold:
///
/// - **Into `waitingForInput`** the cost of being wrong is high: it badges the
///   phone grid and can fire a push telling the user an agent is asking them
///   something when it is not. That direction now needs sustained quiet.
/// - **Out of `waitingForInput`** the cost of being wrong is low and the cost of
///   being slow is a stale "answer me" badge, so it stays fast.
///
/// The added latency is bounded and small — a real prompt is announced ~1s later
/// than before, against a human reaction time measured in seconds.
struct TerminalStateDebounce {

    /// Poll cadence the thresholds below are expressed against.
    static let pollInterval: Double = 0.25

    /// Sustained quiet required before declaring a window is waiting on a human:
    /// 6 polls ≈ 1.5s. A working agent essentially never idles that long inside
    /// a turn; a real prompt idles indefinitely.
    static let pollsToEnterWaiting = 6

    /// Everything else keeps the original 2 polls (~0.5s).
    static let pollsDefault = 2

    static func requiredPolls(from _: TerminalState, to: TerminalState) -> Int {
        to == .waitingForInput ? pollsToEnterWaiting : pollsDefault
    }

    /// Seconds of agreement a transition needs — the human-readable form of
    /// `requiredPolls`, for logs and docs.
    static func requiredSeconds(from: TerminalState, to: TerminalState) -> Double {
        Double(requiredPolls(from: from, to: to)) * pollInterval
    }

    private var pending: [String: (state: TerminalState, count: Int)] = [:]

    /// Feed one poll result. Returns `true` when `detected` has now agreed with
    /// itself long enough to become the window's state.
    mutating func observe(windowId: String, detected: TerminalState, current: TerminalState) -> Bool {
        guard detected != current else {
            pending[windowId] = nil
            return false
        }

        let count = (pending[windowId]?.state == detected ? pending[windowId]!.count : 0) + 1
        guard count >= Self.requiredPolls(from: current, to: detected) else {
            pending[windowId] = (detected, count)
            return false
        }

        pending[windowId] = nil
        return true
    }

    /// Drop any half-accumulated candidate for a window that stopped being
    /// tracked, so a later poll cannot resume counting from a stale run.
    mutating func forget(windowId: String) {
        pending[windowId] = nil
    }

    mutating func forgetAll() {
        pending.removeAll()
    }
}
