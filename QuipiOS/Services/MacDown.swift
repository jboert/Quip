import Foundation
import Network

/// Q-90 US-001: why the active Mac is unreachable, in the owner's terms.
/// Screen Sharing (TCP 5900) runs without Quip, so a Mac that answers there
/// is up with Quip down; one that does not is offline (asleep, off, or off
/// the network).
enum MacDown: String {
    case quipDown = "quip_down"
    case offline
    /// No probe result (rate-limited or not run yet).
    case unknown

    /// nil when Quip itself answers: nothing is down.
    static func classify(quipReachable: Bool, screenSharingReachable: Bool?) -> MacDown? {
        if quipReachable { return nil }
        switch screenSharingReachable {
        case true?: return .quipDown
        case false?: return .offline
        case nil: return .unknown
        }
    }

    /// The `phone.log` line. Never the host.
    static func logLine(_ kind: MacDown, probeMs: Int) -> String {
        "mac_down kind=\(kind.rawValue) probe_ms=\(probeMs)"
    }
}

/// Probes a Mac's Screen Sharing port, at most once per host per minute.
@MainActor
final class MacDownProbe {
    typealias Connect = (_ host: String, _ port: UInt16, _ timeout: Duration) async -> Bool

    static let port: UInt16 = 5900
    static let timeout: Duration = .seconds(3)
    static let minInterval: Duration = .seconds(60)

    private let connect: Connect
    private let now: () -> ContinuousClock.Instant
    private var lastProbe: [String: ContinuousClock.Instant] = [:]

    init(connect: @escaping Connect = MacDownProbe.networkConnect,
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.connect = connect
        self.now = now
    }

    /// true when 5900 accepts a connection, false when it does not, nil when
    /// this host was probed less than `minInterval` ago (no connect made).
    func probe(host: String) async -> Bool? {
        let start = now()
        if let last = lastProbe[host], start - last < Self.minInterval { return nil }
        lastProbe[host] = start
        return await connect(host, Self.port, Self.timeout)
    }

    /// TCP connect to `host:port`; true once `.ready`. The connection is
    /// cancelled on every exit so no half-open socket outlives the probe
    /// (cf. the latency-probe leak, 1dbd64b).
    nonisolated static func networkConnect(host: String, port: UInt16, timeout: Duration) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(integerLiteral: port), using: .tcp)
        let queue = DispatchQueue(label: "quip.mac-down-probe")
        let c = timeout.components
        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Touched only on `queue`.
                var finished = false
                let finish: (Bool) -> Void = { reachable in
                    guard !finished else { return }
                    finished = true
                    connection.cancel()
                    continuation.resume(returning: reachable)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)
                    case .failed, .waiting, .cancelled: finish(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + seconds) { finish(false) }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
