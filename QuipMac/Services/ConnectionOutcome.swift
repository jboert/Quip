import Foundation

/// Why a connection ended — and, crucially, whether that is worth alarming
/// about.
///
/// `LatencyProbeService` on the phone opens a TCP-only probe to each alternate
/// URL every 60 seconds. It never performs a WebSocket handshake and closes
/// when the next probe supersedes it. That is *routine*, but the old code
/// printed it as `Connection FAILED: reset by peer`, indistinguishable from a
/// real socket dying.
///
/// Reaching `.ready` is NOT the whole discriminator, though — treating every
/// pre-`.ready` close as benign is the same lie pointed the other way. A TLS
/// handshake that fails, an ECONNRESET mid-upgrade, and the phone's
/// NWPathMonitor preempting a dial all die before `.ready` too, and those are
/// exactly the "my phone can't connect" failures websocket.log exists to
/// explain. What actually separates a probe from a broken dial is the *error*:
/// a probe closes with none (the connection is simply cancelled), while a dial
/// that breaks in the handshake surfaces the NWError that broke it. So the
/// classification is two-dimensional — reached ready, and errored.
enum ConnectionOutcome: Equatable {
    /// Closed before the handshake completed and with no error — a probe, a
    /// port scan, or a client that changed its mind. Benign.
    case abortedHandshake
    /// Broke *during* the handshake, carrying the error that broke it. Real:
    /// the phone tried to connect and could not.
    case failedHandshake(String)
    /// An established connection that closed cleanly.
    case closedNormally
    /// An established connection that broke.
    case failed(String)

    static func classify(reachedReady: Bool, error: String?) -> ConnectionOutcome {
        switch (reachedReady, error) {
        case (false, nil): return .abortedHandshake
        case (false, let error?): return .failedHandshake(error)
        case (true, nil): return .closedNormally
        case (true, let error?): return .failed(error)
        }
    }

    /// A pre-handshake break is `.warn`, not `.error`: it is genuinely worth
    /// reading — and must never be filed as routine — but a phone walking out
    /// of Wi-Fi range produces it legitimately, so it does not carry the weight
    /// of an established connection dying.
    var severity: QuipLog.Severity {
        switch self {
        case .abortedHandshake, .closedNormally: return .info
        case .failedHandshake: return .warn
        case .failed: return .error
        }
    }

    func describe(endpoint: String) -> String {
        switch self {
        case .abortedHandshake:
            return "connection from \(endpoint) closed before handshake (probe or abandoned dial)"
        case .failedHandshake(let error):
            return "connection from \(endpoint) broke during handshake — the client never got "
                 + "connected: \(error)"
        case .closedNormally:
            return "connection from \(endpoint) closed"
        case .failed(let error):
            return "established connection from \(endpoint) failed: \(error)"
        }
    }
}
