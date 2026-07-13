// LogTransitionPolicy.swift
// QuipMac — decides *when* a repeating failure is worth a log line.
//
// A log that floods is as useless as a log that stays silent: both bury the
// real signal. Several of Quip's error sites sit on repeating paths — the 2.0s
// window-poll timer, per-window screenshot capture, per-chunk dictation audio —
// where a persistent cause (an unmounted project root, a revoked Screen
// Recording grant, a schema-drifted message) fails EVERY call. Logging those
// unconditionally writes tens of thousands of identical lines a day.
//
// The fix is to log *state transitions* rather than occurrences: the first
// failure, any change of cause, and the recovery. The naive version of that
// idea — one global "last failure" slot — is actively worse than no dedup when
// the path is per-key: with window A failing and window B succeeding, a single
// slot alternates "failed" / "recovered" on every cycle, so it both floods AND
// lies about the recovery. Hence: the state is keyed, and the decision is a
// pure function that can be tested without touching a file or a global.

import Foundation

/// What to do about a condition observed right now, given what was last reported.
enum LogTransition: Equatable {
    /// New failure, or the same key failing for a *different* reason.
    case report
    /// Nothing changed since the last line we wrote — say nothing.
    case stayQuiet
    /// This key was failing and is now healthy.
    case reportRecovery
}

enum LogTransitionPolicy {
    /// Pure decision seam. `previous` is the cause last reported for a key
    /// (nil = the key was healthy); `current` is the cause observed now
    /// (nil = healthy). No state, no I/O — the whole state machine is here so
    /// it can be exercised directly by tests.
    static func decide(previous: String?, current: String?) -> LogTransition {
        switch (previous, current) {
        case (nil, nil):
            return .stayQuiet
        case (nil, _?):
            return .report
        case (_?, nil):
            return .reportRecovery
        case let (previous?, current?):
            return previous == current ? .stayQuiet : .report
        }
    }
}

/// Thread-safe, *keyed* application of `LogTransitionPolicy`.
///
/// The key is the unit of independent health: a `CGWindowID` for screenshot
/// capture, a project-root path for directory scanning, a PTT `sessionId` for
/// audio chunks. Keying is not a nicety — a shared slot across independent
/// units is what turns transition-logging into a flood (see file header).
///
/// The cause string is both the message body and the dedup key, so it must
/// contain no key-identifying data (no window id, no tmp path): two windows
/// failing the same way have to compare *equal* or the guard never holds.
///
/// `@unchecked Sendable` is honest here for the same reason `QuipLog.writeLock`
/// is: the NSLock below provides the actual synchronization, and the mutable
/// state it guards never escapes.
final class LogTransitionGate<Key: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    /// Only *failing* keys are present. Recovery removes the entry, which is
    /// also what bounds this dictionary on long-lived per-window/per-session use.
    private var reported: [Key: String] = [:]

    init() {}

    /// Record what we see now and get back whether it deserves a line.
    /// `cause == nil` means "this key is healthy right now".
    func evaluate(_ key: Key, cause: String?) -> LogTransition {
        lock.lock()
        defer { lock.unlock() }
        let decision = LogTransitionPolicy.decide(previous: reported[key], current: cause)
        switch decision {
        case .report:
            reported[key] = cause
        case .reportRecovery:
            reported.removeValue(forKey: key)
        case .stayQuiet:
            break
        }
        return decision
    }

    /// Test seam: the cause currently on record for `key` (nil = healthy).
    func reportedCause(_ key: Key) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return reported[key]
    }

    /// Test seam: how many keys are currently on record as failing.
    var failingKeyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reported.count
    }
}
