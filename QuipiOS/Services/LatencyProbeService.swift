import Foundation
import Network

/// Phase 3 commit 3: periodic transient TCP probes against the alt URLs in
/// the active backend's `urlsInOrder`, so URLSwapPolicy has data to compare
/// against the connected URL's recent live latency.
///
/// Why TCP-only (no WS handshake):
///   - WS handshake involves auth + PIN + session-restore traffic; firing
///     it every 60s × N URLs would flood the Mac.
///   - TCP-connect time correlates strongly with full-WS RTT for the typical
///     Quip use case (LAN vs Tailscale vs Cloudflare differ by an order of
///     magnitude at the TCP layer; the WS handshake adds a constant).
///   - It's the cheapest possible probe — no app-level state mutation on
///     the Mac, and a connection that gets cancelled mid-handshake doesn't
///     show up in `connectionLog`.
///
/// Probe samples are appended to `WebSocketClient.latencySamples` with
/// `path = "probe"` so the existing latency-summary UI in
/// `SettingsSheet → Diagnostics` can filter them out of the user-facing
/// medians (a TCP-connect time isn't comparable to a real send_text RTT).
@MainActor
final class LatencyProbeService {

    /// Re-probe every 60s. Lower frequencies hide regressions (alt URL
    /// can be down for 4 minutes before we notice); higher frequencies
    /// soak the radio and battery for marginal signal gain.
    nonisolated static let probeInterval: TimeInterval = 60

    /// Cap per-probe wait so a black-holed alt URL doesn't tie the timer
    /// up forever. 5s is roughly 2× the worst LAN round-trip we'd ever
    /// reasonably see, and well under the 60s probe cycle.
    nonisolated static let probeTimeout: TimeInterval = 5

    /// Owning client (where probe samples land). Weak so the service
    /// doesn't keep a dead WebSocketClient alive after backend forget.
    private weak var client: WebSocketClient?

    /// URL provider — closure rather than a snapshot so the service
    /// always probes whichever URLs the active PairedBackend currently
    /// has, even if `paired[active].urlsInOrder` was reordered after
    /// a swap.
    private let urlsProvider: () -> [URL]

    /// Closure that reports the current connection URL so we don't probe
    /// it (we already have live samples). Returns nil when the client is
    /// disconnected; in that case we still probe everything.
    private let currentURLProvider: () -> URL?

    private var timerTask: Task<Void, Never>?

    init(
        client: WebSocketClient,
        urlsProvider: @escaping () -> [URL],
        currentURLProvider: @escaping () -> URL?
    ) {
        self.client = client
        self.urlsProvider = urlsProvider
        self.currentURLProvider = currentURLProvider
    }

    func start() {
        stop()
        timerTask = Task { [weak self] in
            // Initial 2s grace so a freshly-connected client isn't
            // flooded with probes during PIN auth + first layout_update.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                await self?.probeAll()
                try? await Task.sleep(nanoseconds: UInt64(Self.probeInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    deinit { timerTask?.cancel() }

    // MARK: - Probe loop

    /// Probes every URL in the provider that isn't the current one.
    /// Probes are sequential (not parallel) — running 3 concurrent NWConnections
    /// to the same Mac during peak TCP flux skews the radio readings; serial
    /// probes get clean per-URL numbers at a small wall-clock cost.
    private func probeAll() async {
        let urls = urlsProvider()
        let current = currentURLProvider()
        for url in urls where url != current {
            await probe(url: url)
        }
    }

    /// One TCP-connect timing. Records a synthetic LatencySample on the
    /// owning client with the connect-time as `netRtt`. The other timing
    /// fields are zero (probe doesn't go through Mac processing).
    private func probe(url: URL) async {
        guard let host = url.host, !host.isEmpty,
              let port = url.port ?? defaultPort(for: url) else { return }
        let start = Date()
        let rttMs = await tcpConnect(host: host, port: port)
        let _ = start  // start retained for breadcrumb; not used numerically
        guard let rtt = rttMs else {
            // Probe timed out / failed. Emit a sentinel sample so the
            // policy can see the URL is currently unreachable (its
            // bucket score blows past any candidateRatio threshold).
            recordProbeSample(host: host, netRtt: Int(Self.probeTimeout * 1000) + 1)
            return
        }
        recordProbeSample(host: host, netRtt: rtt)
    }

    /// NWConnection-based TCP probe. Returns ms to `.ready` or nil on
    /// timeout / failure. Cancels the connection cleanly either way so we
    /// don't leave half-open sockets behind.
    nonisolated private func tcpConnect(host: String, port: Int) async -> Int? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let nwHost = NWEndpoint.Host(host)
        let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        let start = Date()
        let queue = DispatchQueue(label: "quip.latency-probe")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var resumed = false
                let resumeOnce: (Int?) -> Void = { value in
                    guard !resumed else { return }
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: value)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let ms = Int(Date().timeIntervalSince(start) * 1000)
                        resumeOnce(ms)
                    case .failed, .cancelled:
                        resumeOnce(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)

                // Timeout fallback.
                queue.asyncAfter(deadline: .now() + Self.probeTimeout) {
                    resumeOnce(nil)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Append a synthetic sample to the owning client. Keeps the existing
    /// `latencySamples` cap logic — probe samples count toward the 100-deep
    /// rolling buffer, so a probe-heavy session doesn't silently double the
    /// memory footprint.
    private func recordProbeSample(host: String, netRtt: Int) {
        guard let client else { return }
        let transport = WebSocketClient.LatencyTransport.classify(
            URL(string: "ws://\(host)"))  // best-effort scheme — host-only classifier
        client.appendProbeSample(
            host: host,
            netRtt: netRtt,
            transport: transport
        )
    }

    /// Internet-default ports for the schemes Quip uses. Only fires when the
    /// URL didn't carry an explicit port — typical for `wss://*.trycloudflare.com`
    /// (443) and rare for `ws://`.
    private func defaultPort(for url: URL) -> Int? {
        switch url.scheme {
        case "ws", "http": return 80
        case "wss", "https": return 443
        default: return nil
        }
    }
}
