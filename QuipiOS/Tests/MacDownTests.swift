import Network
import XCTest
@testable import Quip

/// Q-90 US-001: tell "Quip is down" apart from "the Mac is offline".
@MainActor
final class MacDownTests: XCTestCase {
    private let host = "studio.tail1234.ts.net"
    private var clock = ContinuousClock.now
    private var calls: [(host: String, port: UInt16, timeout: Duration)] = []

    private func makeProbe(answers: Bool = true) -> MacDownProbe {
        MacDownProbe(connect: { [unowned self] h, p, t in
                         calls.append((h, p, t))
                         return answers
                     },
                     now: { [unowned self] in clock })
    }

    // MARK: classify

    private func assertClassify(_ classify: (Bool, Bool?) -> MacDown?,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(classify(true, true), file: file, line: line)
        XCTAssertNil(classify(true, false), file: file, line: line)
        XCTAssertNil(classify(true, nil), file: file, line: line)
        XCTAssertEqual(classify(false, true), .quipDown, file: file, line: line)
        XCTAssertEqual(classify(false, false), .offline, file: file, line: line)
        XCTAssertEqual(classify(false, nil), .unknown, file: file, line: line)
    }

    func test_classify_allCases() {
        assertClassify { MacDown.classify(quipReachable: $0, screenSharingReachable: $1) }
    }

    /// Broken fixture: the same assertions must catch .quipDown/.offline
    /// swapped, or the suite fails (strict expected failure).
    func test_classify_assertionsCatchASwappedFixture() {
        let swapped: (Bool, Bool?) -> MacDown? = { quip, ss in
            switch MacDown.classify(quipReachable: quip, screenSharingReachable: ss) {
            case .quipDown?: return .offline
            case .offline?: return .quipDown
            case let other: return other
            }
        }
        XCTExpectFailure("swapped fixture must fail the classify assertions", strict: true)
        assertClassify(swapped)
    }

    func test_rawValues() {
        XCTAssertEqual(MacDown.quipDown.rawValue, "quip_down")
        XCTAssertEqual(MacDown.offline.rawValue, "offline")
        XCTAssertEqual(MacDown.unknown.rawValue, "unknown")
    }

    // MARK: probe

    func test_probe_usesScreenSharingPortAndThreeSecondTimeout() async {
        let probe = makeProbe()
        let r = await probe.probe(host: host)
        XCTAssertEqual(r, true)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.host, host)
        XCTAssertEqual(calls.first?.port, 5900)
        XCTAssertEqual(calls.first?.timeout, .seconds(3))
    }

    func test_probe_passesThroughUnreachable() async {
        let r = await makeProbe(answers: false).probe(host: host)
        XCTAssertEqual(r, false)
    }

    func test_probe_rateLimitedToOncePerMinutePerHost() async {
        let probe = makeProbe()
        _ = await probe.probe(host: host)

        clock = clock.advanced(by: .seconds(59))
        let early = await probe.probe(host: host)
        XCTAssertNil(early)
        XCTAssertEqual(calls.count, 1, "a rate-limited probe makes no connect call")

        // Another host is not held back by this one.
        _ = await probe.probe(host: "other.local")
        XCTAssertEqual(calls.count, 2)

        clock = clock.advanced(by: .seconds(2)) // +61 s
        let late = await probe.probe(host: host)
        XCTAssertEqual(late, true)
        XCTAssertEqual(calls.count, 3)
    }

    // MARK: log line

    func test_logLine_formatAndNoHost() {
        let host = self.host
        let line = MacDown.logLine(.quipDown, probeMs: 42)
        XCTAssertEqual(line, "mac_down kind=quip_down probe_ms=42")
        XCTAssertFalse(line.contains(host))
        XCTAssertEqual(MacDown.logLine(.offline, probeMs: 3001), "mac_down kind=offline probe_ms=3001")
        XCTAssertEqual(MacDown.logLine(.unknown, probeMs: 0), "mac_down kind=unknown probe_ms=0")
    }

    // MARK: production connector

    func test_networkConnect_trueForAListener_falseForAClosedPort() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let open = await MacDownProbe.networkConnect(host: "127.0.0.1", port: port, timeout: .seconds(3))
        XCTAssertTrue(open)

        listener.cancel()
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        let closed = await MacDownProbe.networkConnect(host: "127.0.0.1", port: port, timeout: .seconds(3))
        XCTAssertFalse(closed)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(4))
    }
}
