import XCTest
import Network
@testable import Quip

/// Phase 3 commit 1 (observational widening). Locks the pure classifiers
/// and the variance calc that `handleSendTextAck` uses to tag each
/// LatencySample with transport + signal context. The actual `NWPath`
/// branch is exercised live via NWPathMonitor; here we cover only what
/// can be unit-tested without a real radio.
final class LatencyTaggingTests: XCTestCase {

    // MARK: - LatencyTransport.classify

    func testTransportLocalLAN() {
        XCTAssertEqual(
            WebSocketClient.LatencyTransport.classify(URL(string: "ws://192.168.1.50:8765")),
            .localWS)
    }

    func testTransportLocalLoopback() {
        XCTAssertEqual(
            WebSocketClient.LatencyTransport.classify(URL(string: "ws://127.0.0.1:8765")),
            .localWS)
    }

    func testTransportCloudflareTunnel() {
        XCTAssertEqual(
            WebSocketClient.LatencyTransport.classify(
                URL(string: "wss://something-random.trycloudflare.com")),
            .cloudflareTunnel)
    }

    func testTransportSubdomainOfTrycloudflare() {
        XCTAssertEqual(
            WebSocketClient.LatencyTransport.classify(
                URL(string: "wss://a.b.trycloudflare.com/ws")),
            .cloudflareTunnel)
    }

    func testTransportUnknownWSSHost() {
        // A wss:// to anything other than trycloudflare is a relay we
        // don't model. Don't lump into cloudflareTunnel.
        XCTAssertEqual(
            WebSocketClient.LatencyTransport.classify(
                URL(string: "wss://relay.example.com")),
            .unknown)
    }

    func testTransportNilURL() {
        XCTAssertEqual(WebSocketClient.LatencyTransport.classify(nil), .unknown)
    }

    func testTransportHTTPSchemeIsUnknown() {
        // Defensive: the WS layer should never see http(s):// here, but if
        // a test stubs one in we don't want it silently classified.
        XCTAssertEqual(
            WebSocketClient.LatencyTransport.classify(URL(string: "https://example.com")),
            .unknown)
    }

    // MARK: - WebSocketClient.netVariance

    private func sample(_ netRtt: Int) -> WebSocketClient.LatencySample {
        WebSocketClient.LatencySample(
            timestamp: Date(),
            totalRtt: netRtt + 10,
            injectMs: 5,
            totalMs: 10,
            netRtt: netRtt,
            path: "sendText",
            transport: .localWS,
            networkClass: .wifi,
            netVariance: 0,
            serverURLHost: "192.168.1.50"
        )
    }

    func testVarianceEmpty() {
        XCTAssertEqual(WebSocketClient.netVariance(of: []), 0)
    }

    func testVarianceSingleSample() {
        // One sample has undefined variance — treat as stable (0).
        XCTAssertEqual(WebSocketClient.netVariance(of: [sample(50)]), 0)
    }

    func testVarianceConstantStream() {
        // No spread → variance 0.
        let s = (0..<5).map { _ in sample(100) }
        XCTAssertEqual(WebSocketClient.netVariance(of: s), 0)
    }

    func testVarianceTwoEquidistantSamples() {
        // 90 and 110 around mean 100 → population std-dev = 10.
        XCTAssertEqual(WebSocketClient.netVariance(of: [sample(90), sample(110)]), 10)
    }

    func testVarianceJittery() {
        // Population std-dev of [50,50,50,50,250] = 80
        // (mean 90, sumSq = 4*40^2 + 160^2 = 6400+25600 = 32000; /5 = 6400; sqrt = 80)
        let s = [sample(50), sample(50), sample(50), sample(50), sample(250)]
        XCTAssertEqual(WebSocketClient.netVariance(of: s), 80)
    }

    // MARK: - LatencySample equality keeps the new fields significant

    func testLatencySampleEqualityIncludesTransport() {
        let a = sample(100)
        let b = WebSocketClient.LatencySample(
            timestamp: a.timestamp,
            totalRtt: a.totalRtt,
            injectMs: a.injectMs,
            totalMs: a.totalMs,
            netRtt: a.netRtt,
            path: a.path,
            transport: .cloudflareTunnel,  // changed
            networkClass: a.networkClass,
            netVariance: a.netVariance,
            serverURLHost: a.serverURLHost
        )
        XCTAssertNotEqual(a, b, "Samples differing only in transport must not compare equal")
    }

    func testLatencySampleEqualityIncludesNetworkClass() {
        let a = sample(100)
        let b = WebSocketClient.LatencySample(
            timestamp: a.timestamp,
            totalRtt: a.totalRtt,
            injectMs: a.injectMs,
            totalMs: a.totalMs,
            netRtt: a.netRtt,
            path: a.path,
            transport: a.transport,
            networkClass: .cellular,  // changed
            netVariance: a.netVariance,
            serverURLHost: a.serverURLHost
        )
        XCTAssertNotEqual(a, b, "Samples differing only in networkClass must not compare equal")
    }

    func testLatencySampleEqualityIncludesServerURLHost() {
        let a = sample(100)
        let b = WebSocketClient.LatencySample(
            timestamp: a.timestamp,
            totalRtt: a.totalRtt,
            injectMs: a.injectMs,
            totalMs: a.totalMs,
            netRtt: a.netRtt,
            path: a.path,
            transport: a.transport,
            networkClass: a.networkClass,
            netVariance: a.netVariance,
            serverURLHost: "100.71.210.27"  // changed: same transport bucket, different host
        )
        XCTAssertNotEqual(a, b, "Samples differing only in serverURLHost must not compare equal — URLSwapPolicy needs per-host bucketing")
    }
}
