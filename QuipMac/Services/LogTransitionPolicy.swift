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

/// A cause string safe to feed a `LogTransitionGate` — one that compares EQUAL
/// across two occurrences of the same fault.
///
/// Interpolating an error is the trap. `"\(error)"` renders a Cocoa `NSError`'s
/// `userInfo` dictionary, whose key order is not stable, so the same fault
/// yields a different string each time; a cause that never compares equal never
/// suppresses, and the gate silently becomes a no-op on the very path it was
/// protecting. That is not confined to errors that ARE an NSError: a
/// `DecodingError.dataCorrupted` from `JSONDecoder` embeds the
/// `JSONSerialization` NSError in its context and renders it too (measured: 200
/// identical corrupt-JSON failures → 2 distinct strings, and it is 2 only
/// because a two-key userInfo has just two orderings). Swift's own
/// `typeMismatch` / `keyNotFound` / `valueNotFound` interpolate stably, but
/// telling those apart at a call site is exactly the reasoning nobody should
/// have to do — key on the fault's SHAPE and the question never comes up.
enum StableCause {
    static func text(for error: Error) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            let joined = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return joined.isEmpty ? "<root>" : joined
        }
        switch error {
        case let DecodingError.keyNotFound(key, ctx):
            return "missing key '\(key.stringValue)' at \(path(ctx))"
        case let DecodingError.typeMismatch(type, ctx):
            return "wrong type for \(type) at \(path(ctx))"
        case let DecodingError.valueNotFound(type, ctx):
            return "missing value for \(type) at \(path(ctx))"
        case let DecodingError.dataCorrupted(ctx):
            // The context's own debugDescription is stable; the underlying
            // NSError that `"\(error)"` would also print is not.
            return "corrupt data at \(path(ctx)): \(ctx.debugDescription)"
        default:
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        }
    }
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

    /// Recovery is NOT a bound. Keys here are per-subject and many subjects die
    /// broken and never recover: a `CGWindowID` that fails capture and then
    /// closes (and CGWindowIDs are never reused), a PTT `sessionId` whose every
    /// chunk fails to decode (one dead key per press, forever). Tens of bytes
    /// each, but a process that runs for weeks accumulates them without limit.
    /// So the map is capacity-bounded: past the cap, the oldest failing key is
    /// evicted. An evicted key that is still broken simply reports again the
    /// next time it fails — one extra line, not a flood, and only in the
    /// degenerate case where this many subjects are failing at once.
    private static var defaultCapacity: Int { 512 }

    private let lock = NSLock()
    private let capacity: Int
    /// Only *failing* keys are present; recovery removes the entry.
    private var reported: [Key: String] = [:]
    /// The failing keys in first-report order — the eviction queue. Kept in
    /// lockstep with `reported`, so it is the same size and the same members.
    private var order: [Key] = []

    init(capacity: Int? = nil) {
        self.capacity = max(1, capacity ?? Self.defaultCapacity)
    }

    /// Record what we see now and get back whether it deserves a line.
    /// `cause == nil` means "this key is healthy right now".
    func evaluate(_ key: Key, cause: String?) -> LogTransition {
        lock.lock()
        defer { lock.unlock() }
        let decision = LogTransitionPolicy.decide(previous: reported[key], current: cause)
        switch decision {
        case .report:
            if reported[key] == nil { order.append(key) }
            reported[key] = cause
            evictOldestIfOverCapacity()
        case .reportRecovery:
            forgetLocked(key)
        case .stayQuiet:
            break
        }
        return decision
    }

    /// Forget a key whose subject is gone — a closed window, a finished PTT
    /// session. Not required for correctness (the capacity bound above holds
    /// regardless), but a caller that knows a subject is dead can say so and
    /// keep the map at its true working size.
    func forget(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }
        forgetLocked(key)
    }

    private func forgetLocked(_ key: Key) {
        guard reported.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    private func evictOldestIfOverCapacity() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            reported.removeValue(forKey: oldest)
        }
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
