import Foundation

/// Why a connection ended — and, crucially, whether that is worth alarming
/// about.
///
/// `LatencyProbeService` on the phone opens a TCP-only probe to each alternate
/// URL every 60 seconds. It never performs a WebSocket handshake and closes
/// when the next probe supersedes it. That is *routine*, but the old code
/// printed it as `Connection FAILED: reset by peer`, indistinguishable from a
/// real socket dying. The discriminator is simple: did the connection ever
/// reach `.ready` (i.e. complete the handshake)?
enum ConnectionOutcome: Equatable {
    /// Closed before the handshake completed — a probe, a port scan, or a
    /// client that changed its mind. Benign.
    case abortedHandshake
    /// An established connection that closed cleanly.
    case closedNormally
    /// An established connection that broke. The only real failure.
    case failed(String)

    static func classify(reachedReady: Bool, error: String?) -> ConnectionOutcome {
        guard reachedReady else { return .abortedHandshake }
        guard let error else { return .closedNormally }
        return .failed(error)
    }

    var severity: QuipLog.Severity {
        switch self {
        case .abortedHandshake, .closedNormally: return .info
        case .failed: return .error
        }
    }

    func describe(endpoint: String) -> String {
        switch self {
        case .abortedHandshake:
            return "connection from \(endpoint) closed before handshake (probe or abandoned dial)"
        case .closedNormally:
            return "connection from \(endpoint) closed"
        case .failed(let error):
            return "established connection from \(endpoint) failed: \(error)"
        }
    }
}
