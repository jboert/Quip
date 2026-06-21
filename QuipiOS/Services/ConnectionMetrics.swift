// ConnectionMetrics.swift
// QuipiOS — Pure, in-memory aggregation of connection-lifecycle events so the
// in-app diagnostics view (and a future support export) can answer "how is the
// link actually behaving?" without a Mac attached. Deliberately a value type
// with no I/O and no Date() calls — callers pass elapsed milliseconds — so it
// unit-tests deterministically.

import Foundation

struct ConnectionMetrics: Codable, Equatable {
    /// Every socket attempt (initial connect + each failover + each reconnect).
    private(set) var connectAttempts = 0
    /// Attempts that reached a successful `auth_result`.
    private(set) var successfulAuths = 0
    /// Times the client advanced to the next candidate URL.
    private(set) var failovers = 0
    /// Disconnects bucketed by `DisconnectReason` label.
    private(set) var disconnectsByReason: [String: Int] = [:]
    /// Bounded ring of time-from-socket-start to auth-success, in ms.
    private(set) var timeToAuthMsSamples: [Int] = []

    static let maxSamples = 50

    mutating func recordConnectAttempt() { connectAttempts += 1 }

    mutating func recordAuthSuccess(timeToAuthMs: Int) {
        successfulAuths += 1
        timeToAuthMsSamples.append(max(0, timeToAuthMs))
        if timeToAuthMsSamples.count > Self.maxSamples {
            timeToAuthMsSamples.removeFirst(timeToAuthMsSamples.count - Self.maxSamples)
        }
    }

    mutating func recordFailover() { failovers += 1 }

    mutating func recordDisconnect(reason: String) {
        disconnectsByReason[reason, default: 0] += 1
    }

    /// Auth successes / connect attempts. 0 when nothing has been attempted.
    var authSuccessRate: Double {
        connectAttempts == 0 ? 0 : Double(successfulAuths) / Double(connectAttempts)
    }

    /// Nearest-rank percentile of time-to-auth (p in 0...1). nil with no samples.
    func percentileTimeToAuthMs(_ p: Double) -> Int? {
        guard !timeToAuthMsSamples.isEmpty else { return nil }
        let sorted = timeToAuthMsSamples.sorted()
        let clamped = min(max(p, 0), 1)
        let idx = min(sorted.count - 1, Int((clamped * Double(sorted.count - 1)).rounded()))
        return sorted[idx]
    }

    /// Human-readable single-block summary for the diagnostics sheet / export.
    func formattedReport() -> String {
        var lines = [
            "Connection metrics",
            "  attempts: \(connectAttempts)  authed: \(successfulAuths)  "
                + "success: \(Int((authSuccessRate * 100).rounded()))%",
            "  failovers: \(failovers)",
        ]
        if let p50 = percentileTimeToAuthMs(0.5), let p95 = percentileTimeToAuthMs(0.95) {
            lines.append("  time-to-auth: p50 \(p50)ms  p95 \(p95)ms  (n=\(timeToAuthMsSamples.count))")
        } else {
            lines.append("  time-to-auth: no samples yet")
        }
        if disconnectsByReason.isEmpty {
            lines.append("  disconnects: none")
        } else {
            let parts = disconnectsByReason.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
            lines.append("  disconnects: " + parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}
