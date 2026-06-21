// DisconnectReason.swift
// QuipiOS — structured classification of *why* the WebSocket dropped.
//
// Before §30/2: the only signal the UI had was `WebSocketClient.lastError`,
// a free-form string set by every disconnect site. The §K top-bar pill
// fell back to keyword-matching that string ("auth"/"pin" → orange,
// "stalled"/"timed out" → red) which silently broke whenever a new
// disconnect site set a string that didn't contain any of those tokens.
//
// This enum is the canonical source. Each disconnect site sets a typed
// reason; `lastError` becomes a derived label string. The §K pill reads
// the reason directly via `topBarStatus`.
//
// Keep `Equatable` so tests can assert `XCTAssertEqual(reason, .timedOut)`
// without going through the label string.

import Foundation

enum DisconnectReason: Equatable, Sendable {
    /// User tapped Disconnect, Forget, or pressed Reset. Not an error.
    case userInitiated

    /// 8-second initial-connect timeout fired without ever seeing
    /// the first ping reply.
    case timedOut

    /// 25-second stall watchdog tripped after `seconds` in connecting
    /// state without progress (covers the "Connecting forever" case
    /// §44 was originally written for).
    case stalled(seconds: Int)

    /// Server returned `auth_result success=false`. `message` is the
    /// human-readable reason from the Mac (e.g. "Wrong PIN", "PIN
    /// throttled — try again in 30s") when present.
    case authFailed(message: String?)

    /// URLSession-level error (Wi-Fi join/leave, DNS, TLS, host
    /// unreachable). `description` is the localized error text.
    case networkError(String)

    /// Server sent a close frame or the WebSocketTask cancellation
    /// landed with a normal closure code.
    case serverClosed

    /// Disconnect happened but the cause was never classified. Typically
    /// means a new code path is dropping the connection without setting
    /// the reason — log the lastError string and add a case here.
    case unknown

    /// Human-readable label for `lastError` and the diagnostic sheet.
    /// Stable across releases — the §B17 trace process greps for these
    /// tokens, so renames need a coordinated bump.
    var label: String {
        switch self {
        case .userInitiated:
            return "Disconnected"
        case .timedOut:
            return "Connection timed out"
        case .stalled(let secs):
            return "Stalled \(secs)s — resetting"
        case .authFailed(let msg):
            if let msg, !msg.isEmpty {
                return "Auth failed: \(msg)"
            }
            return "Auth failed"
        case .networkError(let desc):
            return desc
        case .serverClosed:
            return "Server closed connection"
        case .unknown:
            return "Disconnected"
        }
    }

    /// Maps to the §K top-bar pill's 4 non-connected states.
    /// `userInitiated` returns nil — the caller decides whether to
    /// show `.unpaired` (no paired backends left) or `.stalled` (still
    /// paired, waiting for auto-reconnect).
    var topBarStatus: TopBarStatus? {
        switch self {
        case .authFailed:
            return .authFailed
        case .stalled, .timedOut, .networkError, .serverClosed, .unknown:
            return .stalled
        case .userInitiated:
            return nil
        }
    }

    /// Diagnostic-friendly short tag — the bare enum case name with no
    /// associated values. Used by DiagnosticsSnapshotFormatter so logs
    /// stay grep-friendly even when the label string changes wording.
    var tag: String {
        switch self {
        case .userInitiated:    return "userInitiated"
        case .timedOut:         return "timedOut"
        case .stalled:          return "stalled"
        case .authFailed:       return "authFailed"
        case .networkError:     return "networkError"
        case .serverClosed:     return "serverClosed"
        case .unknown:          return "unknown"
        }
    }

    /// User-facing one-liner for the §K pill / connection banner. Distinct from
    /// `label` (diagnostic) — phrased for a person, and signals whether we're
    /// auto-recovering ("…") or need them to act.
    var userMessage: String {
        switch self {
        case .userInitiated:    return "Disconnected."
        case .timedOut:         return "Couldn't reach your Mac — retrying…"
        case .stalled:          return "Connection stalled — reconnecting…"
        case .authFailed(let msg):
            if let msg, !msg.isEmpty { return "Couldn't authenticate: \(msg)" }
            return "Couldn't authenticate — check your PIN."
        case .networkError:     return "Network changed — reconnecting…"
        case .serverClosed:     return "Your Mac closed the connection — reconnecting…"
        case .unknown:          return "Connection lost — reconnecting…"
        }
    }

    /// True when the client auto-reconnects from this state (transient); false
    /// when it needs the user (auth) or was user-initiated. Drives whether the
    /// UI shows a "reconnecting" spinner vs an actionable prompt.
    var isRetryable: Bool {
        switch self {
        case .timedOut, .stalled, .networkError, .serverClosed, .unknown:
            return true
        case .authFailed, .userInitiated:
            return false
        }
    }
}
