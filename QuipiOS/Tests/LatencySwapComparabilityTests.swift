import XCTest
@testable import Quip

/// Why the phone never once moved to LAN, in two layers.
///
/// Layer 1: `evaluateSwap` gates on `latencyAutoSwapEnabled`, and
/// `UserDefaults.bool(forKey:)` returns false for a key nobody ever set. The
/// whole swap engine has been dark since it shipped — 20 authenticated connects
/// in one day, every one over Tailscale, with a LAN path advertised by Bonjour
/// and probed every 60s the entire time.
///
/// Layer 2, and the reason turning the toggle on would not have been enough:
/// the two sides of the comparison were measuring different things.
/// `LatencyProbeService.probeAll` skipped the URL it was already connected to,
/// so the current URL's bucket held only live samples — a full WebSocket round
/// trip, phone send to phone ack — while every candidate's bucket held only
/// TCP-connect times. A TCP handshake is structurally cheaper than an
/// application round trip, so ANY candidate looked dramatically faster than the
/// URL in use, including a genuinely worse one. The 0.7 ratio guards sampling
/// noise; it does not guard a unit mismatch.
final class LatencySwapComparabilityTests: XCTestCase {

    private let lan = URL(string: "ws://192.168.4.26:8765")!
    private let ts  = URL(string: "ws://100.120.141.122:8765")!

    private func sample(host: String, netRtt: Int, path: String) -> WebSocketClient.LatencySample {
        WebSocketClient.LatencySample(
            timestamp: Date(), totalRtt: netRtt + 10, injectMs: 5, totalMs: 10,
            netRtt: netRtt, path: path, transport: .localWS, networkClass: .wifi,
            netVariance: 0, serverURLHost: host)
    }

    // MARK: - Layer 2: compare like with like

    /// The exact production shape before the fix: current URL carries live
    /// round-trip samples, candidate carries TCP-connect probes. Even with the
    /// candidate's raw numbers far lower, this must NOT trigger a swap — the
    /// numbers are not comparable, so the policy has no evidence either way.
    func test_liveRoundTripsAreNeverComparedAgainstTcpProbes() {
        let s = [90, 95, 92, 88].map { sample(host: "100.120.141.122", netRtt: $0, path: "sendText") }
              + [3, 2, 3, 2].map { sample(host: "192.168.4.26", netRtt: $0, path: "probe") }
        XCTAssertNil(
            URLSwapPolicy.decide(currentURL: ts, candidates: [ts, lan], samples: s, lastSwapAt: nil),
            "a TCP connect is cheaper than a full app round trip by construction — "
            + "comparing them would promote a candidate that is actually slower")
    }

    /// With both sides measured the same way, the decision is sound and the
    /// swap fires. This is what the fix makes possible: probe the current URL
    /// too, and every bucket is TCP-connect ms.
    func test_probeVersusProbe_swapsToTheFasterPath() {
        let s = [60, 58, 62, 59].map { sample(host: "100.120.141.122", netRtt: $0, path: "probe") }
              + [3, 2, 3, 2].map { sample(host: "192.168.4.26", netRtt: $0, path: "probe") }
        XCTAssertEqual(
            URLSwapPolicy.decide(currentURL: ts, candidates: [ts, lan], samples: s, lastSwapAt: nil),
            lan)
    }

    /// The bias runs both ways, and this is the dangerous direction: a LAN path
    /// that is genuinely worse than the relay must not win just because its
    /// numbers come from a cheaper kind of measurement.
    func test_slowerCandidateDoesNotWinOnMeasurementKindAlone() {
        let s = [20, 21, 19, 20].map { sample(host: "100.120.141.122", netRtt: $0, path: "sendText") }
              + [40, 41, 39, 40].map { sample(host: "192.168.4.26", netRtt: $0, path: "probe") }
        XCTAssertNil(
            URLSwapPolicy.decide(currentURL: ts, candidates: [ts, lan], samples: s, lastSwapAt: nil))
    }

    /// Live samples still belong in the buffer — Diagnostics renders them — so
    /// the bucketing helper must filter them out rather than the buffer never
    /// containing them.
    func test_bucketKeepsProbesAndDropsLiveSamplesForTheSameHost() {
        let s = [1, 2, 3].map { sample(host: "192.168.4.26", netRtt: $0, path: "probe") }
              + [50, 51].map { sample(host: "192.168.4.26", netRtt: $0, path: "sendText") }
        let bucket = URLSwapPolicy.samplesForHost("192.168.4.26", samples: s)
        XCTAssertEqual(bucket.count, 3)
        XCTAssertTrue(bucket.allSatisfy { $0.path == "probe" })
    }

    // MARK: - Probe coverage

    /// The current URL must be probed like every other. Skipping it was what
    /// left its bucket with nothing but live samples to compare against.
    func test_currentURLIsProbedToo() {
        let urls = LatencyProbeService.urlsToProbe([ts, lan], current: ts)
        XCTAssertTrue(urls.contains(ts), "the connected URL needs probe samples of its own, "
                      + "or there is nothing comparable to score candidates against")
        XCTAssertTrue(urls.contains(lan))
    }

    /// Duplicates in the paired list must not double-probe one host per cycle.
    func test_probeListIsDeduplicated() {
        XCTAssertEqual(LatencyProbeService.urlsToProbe([ts, lan, ts], current: ts).count, 2)
    }

    /// Disconnected (no current URL) still probes everything.
    func test_probesEverythingWhenDisconnected() {
        XCTAssertEqual(LatencyProbeService.urlsToProbe([ts, lan], current: nil).count, 2)
    }

    // MARK: - Layer 1: the toggle nobody ever turned on

    /// A user who has never opened Settings → Diagnostics → Latency must still
    /// get the faster path. Unset means on.
    func test_autoSwapDefaultsToOnWhenNeverConfigured() {
        let d = UserDefaults(suiteName: "quip.tests.autoswap.unset")!
        d.removePersistentDomain(forName: "quip.tests.autoswap.unset")
        XCTAssertTrue(BackendConnectionManager.autoSwapEnabled(d))
    }

    /// An explicit opt-out still wins — the default only fills the gap.
    func test_explicitOptOutIsHonoured() {
        let d = UserDefaults(suiteName: "quip.tests.autoswap.off")!
        d.removePersistentDomain(forName: "quip.tests.autoswap.off")
        d.set(false, forKey: BackendConnectionManager.autoSwapDefaultsKey)
        XCTAssertFalse(BackendConnectionManager.autoSwapEnabled(d))
    }

    func test_explicitOptInIsHonoured() {
        let d = UserDefaults(suiteName: "quip.tests.autoswap.on")!
        d.removePersistentDomain(forName: "quip.tests.autoswap.on")
        d.set(true, forKey: BackendConnectionManager.autoSwapDefaultsKey)
        XCTAssertTrue(BackendConnectionManager.autoSwapEnabled(d))
    }
}
