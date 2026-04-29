import Foundation

/// Per-host failure throttle for the WebSocket auth path. Used on the direct
/// LAN connection path; the Cloudflare-tunnel path lives in CloudflareTunnel
/// and proxies all requests through 127.0.0.1, so per-IP lockout is useless
/// there — Cloudflare's edge handles that side's DDoS / brute-force concerns.
///
/// Policy:
///   - Each failed PIN attempt adds `perFailDelayMs` to the next response,
///     capped at `maxDelayMs` (so the *N*th wrong PIN waits ~min(N*200ms, 2s)
///     before getting an answer).
///   - After `maxFailsBeforeLockout` consecutive failures, the host is locked
///     out for `lockoutDuration`. While locked, any auth attempt is rejected
///     immediately without a PIN check.
///   - A successful auth resets the per-host counter to zero.
///   - Stale entries (no activity for an hour, no active lockout) are GC'd
///     on every check so a long-running server doesn't accumulate state.
@MainActor
final class AuthThrottle {

    static let maxFailsBeforeLockout = 10
    static let perFailDelayMs = 200
    static let maxDelayMs = 2_000
    static let lockoutDuration: TimeInterval = 15 * 60     // 15 minutes
    static let staleEntryAge: TimeInterval = 3_600         // 1 hour

    enum Decision: Equatable {
        /// Accept the auth attempt; sleep this long before responding.
        case proceed(delayMs: Int)
        /// Reject without checking the PIN; this much time left on the lockout.
        case locked(remaining: TimeInterval)
    }

    private struct Entry {
        var fails: Int = 0
        var lockoutUntil: Date?
        var lastAttempt: Date = Date()
    }

    private var entries: [String: Entry] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Decide whether to allow this auth attempt and how long to delay the
    /// response. Idempotent: calling `check` doesn't itself record a failure;
    /// the caller decides based on the PIN comparison.
    func check(host: String) -> Decision {
        gc()
        let nowDate = now()
        var entry = entries[host] ?? Entry(lastAttempt: nowDate)

        if let until = entry.lockoutUntil {
            if until > nowDate {
                entries[host] = entry
                return .locked(remaining: until.timeIntervalSince(nowDate))
            }
            // Lockout expired — reset.
            entry.fails = 0
            entry.lockoutUntil = nil
        }

        let delay = min(Self.maxDelayMs, entry.fails * Self.perFailDelayMs)
        entries[host] = entry
        return .proceed(delayMs: delay)
    }

    func recordFailure(host: String) {
        let nowDate = now()
        var entry = entries[host] ?? Entry(lastAttempt: nowDate)
        entry.fails += 1
        entry.lastAttempt = nowDate
        if entry.fails >= Self.maxFailsBeforeLockout {
            entry.lockoutUntil = nowDate.addingTimeInterval(Self.lockoutDuration)
        }
        entries[host] = entry
    }

    func recordSuccess(host: String) {
        entries.removeValue(forKey: host)
    }

    /// Remove entries that have been idle for an hour and aren't actively
    /// locked out. Bounds memory on a long-running server.
    private func gc() {
        let nowDate = now()
        entries = entries.filter { _, entry in
            if let until = entry.lockoutUntil, until > nowDate { return true }
            return nowDate.timeIntervalSince(entry.lastAttempt) < Self.staleEntryAge
        }
    }

    /// Reduce a connection's `NWEndpoint` description to a per-host key. We
    /// strip the ephemeral port so 10 attempts from one attacker on different
    /// ports count toward one bucket. IPv6 endpoints arrive bracketed
    /// (`[::1]:54321` → `[::1]`), so the last-colon heuristic is correct for
    /// both families.
    static func host(from endpoint: String) -> String {
        guard let lastColon = endpoint.lastIndex(of: ":") else { return endpoint }
        return String(endpoint[..<lastColon])
    }
}
