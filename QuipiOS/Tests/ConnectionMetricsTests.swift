import XCTest
@testable import Quip

/// Pure value-in / value-out tests for the connection metrics aggregator.
final class ConnectionMetricsTests: XCTestCase {

    func testCountersIncrement() {
        var m = ConnectionMetrics()
        m.recordConnectAttempt(); m.recordConnectAttempt()
        m.recordFailover()
        m.recordAuthSuccess(timeToAuthMs: 100)
        XCTAssertEqual(m.connectAttempts, 2)
        XCTAssertEqual(m.failovers, 1)
        XCTAssertEqual(m.successfulAuths, 1)
    }

    func testAuthSuccessRateEmptySafe() {
        var m = ConnectionMetrics()
        XCTAssertEqual(m.authSuccessRate, 0, "no divide-by-zero on empty")
        m.recordConnectAttempt(); m.recordConnectAttempt(); m.recordConnectAttempt()
        m.recordAuthSuccess(timeToAuthMs: 50)
        XCTAssertEqual(m.authSuccessRate, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testDisconnectHistogram() {
        var m = ConnectionMetrics()
        m.recordDisconnect(reason: "timed out")
        m.recordDisconnect(reason: "timed out")
        m.recordDisconnect(reason: "auth failed")
        XCTAssertEqual(m.disconnectsByReason["timed out"], 2)
        XCTAssertEqual(m.disconnectsByReason["auth failed"], 1)
    }

    func testPercentilesNearestRank() {
        var m = ConnectionMetrics()
        XCTAssertNil(m.percentileTimeToAuthMs(0.5), "nil with no samples")
        for v in [10, 20, 30, 40, 100] { m.recordAuthSuccess(timeToAuthMs: v) }
        XCTAssertEqual(m.percentileTimeToAuthMs(0.0), 10)
        XCTAssertEqual(m.percentileTimeToAuthMs(0.5), 30)
        XCTAssertEqual(m.percentileTimeToAuthMs(0.95), 100)
    }

    func testSamplesBounded() {
        var m = ConnectionMetrics()
        for i in 0..<(ConnectionMetrics.maxSamples + 20) { m.recordAuthSuccess(timeToAuthMs: i) }
        XCTAssertEqual(m.timeToAuthMsSamples.count, ConnectionMetrics.maxSamples)
        XCTAssertEqual(m.timeToAuthMsSamples.last, ConnectionMetrics.maxSamples + 19, "newest kept")
    }

    func testNegativeTimeClampedToZero() {
        var m = ConnectionMetrics()
        m.recordAuthSuccess(timeToAuthMs: -5)
        XCTAssertEqual(m.timeToAuthMsSamples, [0])
    }

    func testFormattedReportContainsKeyFields() {
        var m = ConnectionMetrics()
        m.recordConnectAttempt(); m.recordAuthSuccess(timeToAuthMs: 42)
        m.recordDisconnect(reason: "stalled")
        let r = m.formattedReport()
        XCTAssertTrue(r.contains("attempts: 1"), r)
        XCTAssertTrue(r.contains("stalled=1"), r)
        XCTAssertTrue(r.contains("p50"), r)
    }

    func testFormattedReportEmptySafe() {
        let r = ConnectionMetrics().formattedReport()
        XCTAssertTrue(r.contains("no samples yet"))
        XCTAssertTrue(r.contains("disconnects: none"))
    }

    func testCodableRoundTrip() {
        var m = ConnectionMetrics()
        m.recordConnectAttempt(); m.recordAuthSuccess(timeToAuthMs: 7); m.recordDisconnect(reason: "x")
        let data = try! JSONEncoder().encode(m)
        let back = try! JSONDecoder().decode(ConnectionMetrics.self, from: data)
        XCTAssertEqual(m, back)
    }
}
