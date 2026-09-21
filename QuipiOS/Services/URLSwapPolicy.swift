import Foundation

/// Phase 3 commit 3: pure decision logic for "should we hot-swap to a faster
/// URL?" Holds no state — caller passes the latency buffer + last-swap timestamp
/// and gets back the URL to swap to (or nil to stay put).
///
/// Kept separate from `BackendConnectionManager` because the swap rule is the
/// part most likely to need tuning after a week of latency.log data, and a
/// pure value-in / value-out function is the cheapest unit-test surface.
enum URLSwapPolicy {

    /// Threshold expressed as a multiplier on the current URL's avg netRtt.
    /// Candidate must beat that ratio to be considered. 0.7 = candidate
    /// must be at least 30% faster. Conservative starting value — at 0.9
    /// (10%) probe noise dominates; at 0.5 (50%) only catastrophic
    /// regressions trigger.
    static let candidateRatio: Double = 0.7

    /// Hysteresis floor in seconds. After a swap, no further swap can fire
    /// for this many seconds — prevents the "ping-pong" failure mode where
    /// the freshly-promoted URL's first sample is unrepresentative and
    /// flips us back. 5 minutes matches the Mac-side connection-stability
    /// budget noted in WebSocketServer.swift's reconnect comments.
    static let swapCooldownSeconds: TimeInterval = 5 * 60

    /// Minimum samples per URL before it can either lose its slot or take
    /// someone else's. Below this, we don't have enough signal to swap
    /// confidently — probe noise can dominate a 1-2 sample average.
    static let minSamplesPerURL = 3

    /// How many of the candidate's most-recent samples must each beat the
    /// current URL's average. Belt-and-braces against the candidate having
    /// one anomalously fast sample dragging its mean down.
    static let consecutiveBeatsRequired = 3

    /// Returns the URL to swap to, or nil to stay put. `samples` is a flat
    /// view of every LatencySample on the active client (same client, has
    /// been on multiple URLs over time after past swaps; the host tag
    /// disambiguates).
    static func decide(
        currentURL: URL,
        candidates: [URL],
        samples: [WebSocketClient.LatencySample],
        lastSwapAt: Date?,
        now: Date = Date()
    ) -> URL? {
        // Hysteresis: too soon since last swap.
        if let last = lastSwapAt,
           now.timeIntervalSince(last) < swapCooldownSeconds {
            return nil
        }

        guard let currentHost = currentURL.host else { return nil }
        let currentSamples = samplesForHost(currentHost, samples: samples)
        guard currentSamples.count >= minSamplesPerURL else { return nil }
        let currentAvg = avgNetRtt(currentSamples)
        guard currentAvg > 0 else { return nil }
        let threshold = currentAvg * candidateRatio

        // Score each candidate. Pick the best scorer that clears the bar.
        var best: (url: URL, avg: Double)?
        for candidate in candidates where candidate != currentURL {
            guard let host = candidate.host else { continue }
            let bucket = samplesForHost(host, samples: samples)
            guard bucket.count >= minSamplesPerURL else { continue }
            let avg = avgNetRtt(bucket)
            guard avg > 0, avg < threshold else { continue }

            // Last-N consecutive sanity check. Defends against an alt URL
            // whose mean has been tugged down by one outlier sample.
            let lastN = Array(bucket.suffix(consecutiveBeatsRequired))
            guard lastN.count >= consecutiveBeatsRequired,
                  lastN.allSatisfy({ Double($0.netRtt) < currentAvg }) else { continue }

            if best == nil || avg < best!.avg {
                best = (candidate, avg)
            }
        }
        return best?.url
    }

    // MARK: - Helpers

    /// The measurement kind this policy scores on. Probes are the only signal
    /// every URL has: the connected URL is the only one that can produce live
    /// round-trips, so admitting live samples would compare a full WebSocket
    /// round trip on one side against a bare TCP connect on the other. A TCP
    /// handshake is cheaper than an app round trip by construction, so that
    /// comparison promoted any candidate over the URL in use — including a
    /// slower one. Live samples stay in the buffer for Diagnostics; they just
    /// do not vote here.
    static let comparableSamplePath = "probe"

    /// Most recent (≤10) PROBE samples whose `serverURLHost` matches `host`.
    /// Window kept small so a freshly-promoted URL can earn its keep without
    /// 100 stale samples blocking the next decision.
    static func samplesForHost(
        _ host: String,
        samples: [WebSocketClient.LatencySample]
    ) -> [WebSocketClient.LatencySample] {
        Array(samples
            .filter { $0.serverURLHost == host && $0.path == comparableSamplePath }
            .suffix(10))
    }

    private static func avgNetRtt(_ samples: [WebSocketClient.LatencySample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0) { $0 + $1.netRtt }
        return Double(total) / Double(samples.count)
    }
}
