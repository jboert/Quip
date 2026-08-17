import XCTest
@testable import Quip

/// Phase 3 commit 3. Locks the decision matrix for URLSwapPolicy.decide.
/// Tests are pure value-in / value-out — no NWConnection, no real timing.
/// Every threshold rule (cooldown, minSamples, candidateRatio, consecutive
/// beats) gets at least one test that demonstrates the boundary the rule
/// is supposed to enforce.
final class URLSwapPolicyTests: XCTestCase {

    private let lan  = URL(string: "ws://192.168.1.50:8765")!
    private let ts   = URL(string: "ws://100.71.210.27:8765")!
    private let cf   = URL(string: "wss://abc.trycloudflare.com")!

    // MARK: - sample factory

    /// Defaults to a probe sample because probes are the only kind the policy
    /// scores on — every URL can produce them, so both sides of a comparison
    /// are measuring the same thing. See `LatencySwapComparabilityTests` for
    /// why admitting live round-trip samples here made every candidate look
    /// faster than the URL already in use.
    private func sample(
        host: String,
        netRtt: Int,
        path: String = "probe"
    ) -> WebSocketClient.LatencySample {
        WebSocketClient.LatencySample(
            timestamp: Date(),
            totalRtt: netRtt + 10,
            injectMs: 5,
            totalMs: 10,
            netRtt: netRtt,
            path: path,
            transport: .localWS,
            networkClass: .wifi,
            netVariance: 0,
            serverURLHost: host
        )
    }

    private func samples(host: String, netRtts: [Int]) -> [WebSocketClient.LatencySample] {
        netRtts.map { sample(host: host, netRtt: $0) }
    }

    // MARK: - cooldown

    func testCooldownBlocksSwapEvenWhenAltIsFaster() {
        let now = Date()
        let s = samples(host: "192.168.1.50", netRtts: [200, 200, 200, 200])
            + samples(host: "100.71.210.27", netRtts: [10, 10, 10, 10])
        let lastSwap = now.addingTimeInterval(-60)  // 1 minute ago — inside 5-min cooldown
        let pick = URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts], samples: s,
            lastSwapAt: lastSwap, now: now)
        XCTAssertNil(pick, "Cooldown must block swap regardless of alt-URL speed")
    }

    func testCooldownExpiredAllowsSwap() {
        let now = Date()
        let s = samples(host: "192.168.1.50", netRtts: [200, 200, 200, 200])
            + samples(host: "100.71.210.27", netRtts: [10, 10, 10, 10])
        let lastSwap = now.addingTimeInterval(-(URLSwapPolicy.swapCooldownSeconds + 1))
        let pick = URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts], samples: s,
            lastSwapAt: lastSwap, now: now)
        XCTAssertEqual(pick, ts, "After cooldown, faster URL should win")
    }

    func testNilLastSwapAllowsImmediateSwap() {
        // Cold start — never swapped before, faster URL should be picked.
        let s = samples(host: "192.168.1.50", netRtts: [200, 200, 200, 200])
            + samples(host: "100.71.210.27", netRtts: [10, 10, 10, 10])
        let pick = URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts], samples: s, lastSwapAt: nil)
        XCTAssertEqual(pick, ts)
    }

    // MARK: - minimum sample count

    func testNoSwapWhenCurrentURLHasTooFewSamples() {
        let s = samples(host: "192.168.1.50", netRtts: [200, 200])  // 2 < 3
            + samples(host: "100.71.210.27", netRtts: [10, 10, 10, 10])
        XCTAssertNil(URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts], samples: s, lastSwapAt: nil))
    }

    func testNoSwapWhenCandidateHasTooFewSamples() {
        let s = samples(host: "192.168.1.50", netRtts: [200, 200, 200, 200])
            + samples(host: "100.71.210.27", netRtts: [10, 10])  // 2 < 3
        XCTAssertNil(URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts], samples: s, lastSwapAt: nil))
    }

    // MARK: - candidateRatio threshold

    func testNoSwapWhenCandidateOnlyMarginallyFaster() {
        // current avg 100, candidate avg 80 → ratio 0.8, above 0.7 cutoff.
        let s = samples(host: "192.168.1.50", netRtts: [100, 100, 100, 100])
            + samples(host: "100.71.210.27", netRtts: [80, 80, 80, 80])
        XCTAssertNil(URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts], samples: s, lastSwapAt: nil),
            "Candidate must beat 30% threshold, not just be faster")
    }

    func testSwapWhenCandidateBeatsThreshold() {
        // current avg 100, candidate avg 60 → ratio 0.6, below 0.7 cutoff.
        let s = samples(host: "192.168.1.50", netRtts: [100, 100, 100, 100])
            + samples(host: "100.71.210.27", netRtts: [60, 60, 60, 60])
        XCTAssertEqual(URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts], samples: s, lastSwapAt: nil), ts)
    }

    // MARK: - consecutive beats

    func testNoSwapWhenLastSamplesDoNotConsecutivelyBeatCurrent() {
        // Mean is 60 (well under threshold) but the most-recent sample
        // is slower than current — we don't want to chase a transient
        // dip that's already trending back up.
        let s = samples(host: "192.168.1.50", netRtts: [100, 100, 100, 100])
            + [sample(host: "100.71.210.27", netRtt: 30),
               sample(host: "100.71.210.27", netRtt: 30),
               sample(host: "100.71.210.27", netRtt: 30),
               sample(host: "100.71.210.27", netRtt: 110)]  // last sample worse than current avg
        XCTAssertNil(URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts], samples: s, lastSwapAt: nil),
            "Last-N consecutive guard must reject candidates whose tail isn't winning")
    }

    func testSwapWhenLastSamplesAllBeatCurrent() {
        let s = samples(host: "192.168.1.50", netRtts: [100, 100, 100, 100])
            + samples(host: "100.71.210.27", netRtts: [30, 30, 30, 30, 30])
        XCTAssertEqual(URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts], samples: s, lastSwapAt: nil), ts)
    }

    // MARK: - multi-candidate

    func testPicksFastestAmongMultipleQualifyingCandidates() {
        // current 200; ts 50; cf 30 → both qualify (both <140 = 0.7×200), cf wins.
        let s = samples(host: "192.168.1.50", netRtts: [200, 200, 200, 200])
            + samples(host: "100.71.210.27", netRtts: [50, 50, 50, 50])
            + samples(host: "abc.trycloudflare.com", netRtts: [30, 30, 30, 30])
        XCTAssertEqual(URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts, cf], samples: s, lastSwapAt: nil), cf)
    }

    func testIgnoresCurrentURLWhenInCandidateList() {
        // current is in candidates (typical: caller passes urlsInOrder unchanged);
        // policy must not swap to the URL it's already on.
        let s = samples(host: "192.168.1.50", netRtts: [100, 100, 100, 100])
        let pick = URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan], samples: s, lastSwapAt: nil)
        XCTAssertNil(pick, "Single-candidate (== current) must never swap")
    }

    // MARK: - bucketing helper

    func testSamplesForHostFiltersByExactHost() {
        let s = samples(host: "192.168.1.50", netRtts: [100, 100, 100])
            + samples(host: "100.71.210.27", netRtts: [50, 50])
        XCTAssertEqual(
            URLSwapPolicy.samplesForHost("192.168.1.50", samples: s).count, 3)
        XCTAssertEqual(
            URLSwapPolicy.samplesForHost("100.71.210.27", samples: s).count, 2)
        XCTAssertEqual(
            URLSwapPolicy.samplesForHost("absent.example.com", samples: s).count, 0)
    }

    func testSamplesForHostKeepsOnlyLast10() {
        // 15 samples for one host → bucket retains last 10.
        let s = (1...15).map { sample(host: "192.168.1.50", netRtt: $0) }
        let bucket = URLSwapPolicy.samplesForHost("192.168.1.50", samples: s)
        XCTAssertEqual(bucket.count, 10)
        XCTAssertEqual(bucket.first?.netRtt, 6, "Should drop oldest 5 (1-5)")
        XCTAssertEqual(bucket.last?.netRtt, 15)
    }

    // MARK: - empty / degenerate inputs

    func testNoCandidatesReturnsNil() {
        let s = samples(host: "192.168.1.50", netRtts: [100, 100, 100])
        XCTAssertNil(URLSwapPolicy.decide(
            currentURL: lan, candidates: [], samples: s, lastSwapAt: nil))
    }

    func testEmptySampleBufferReturnsNil() {
        XCTAssertNil(URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts], samples: [], lastSwapAt: nil))
    }

    func testZeroAvgNetRttCurrentReturnsNil() {
        // Pathological: all samples clamped to 0 (clock skew / instant local).
        // Avoid divide-by-zero downstream.
        let s = samples(host: "192.168.1.50", netRtts: [0, 0, 0, 0])
            + samples(host: "100.71.210.27", netRtts: [50, 50, 50, 50])
        XCTAssertNil(URLSwapPolicy.decide(
            currentURL: lan, candidates: [lan, ts], samples: s, lastSwapAt: nil))
    }
}
