import XCTest
@testable import Quip

final class ConnectionOutcomeTests: XCTestCase {

    /// The exact shape of a LatencyProbeService probe: TCP connects, the WS
    /// handshake never completes (never reaches .ready), then the peer closes.
    /// This MUST NOT be reported as a failure — doing so cost a full debugging
    /// session chasing a dual-backend bug that did not exist.
    func test_probeThatNeverHandshook_isBenign_notAFailure() {
        let outcome = ConnectionOutcome.classify(reachedReady: false, error: "reset by peer")
        XCTAssertEqual(outcome, .abortedHandshake)
        XCTAssertEqual(outcome.severity, .info)
        XCTAssertFalse(outcome.describe(endpoint: "192.168.4.34:56767").uppercased().contains("FAILED"))
    }

    /// A socket that DID complete the handshake and then broke is a real error.
    func test_establishedSocketThatDies_isAFailure() {
        let outcome = ConnectionOutcome.classify(reachedReady: true, error: "reset by peer")
        XCTAssertEqual(outcome, .failed("reset by peer"))
        XCTAssertEqual(outcome.severity, .error)
        XCTAssertTrue(outcome.describe(endpoint: "100.72.13.19:56736").contains("reset by peer"))
    }

    /// A clean close of an established socket is normal, not an error.
    func test_establishedSocketClosedCleanly_isBenign() {
        let outcome = ConnectionOutcome.classify(reachedReady: true, error: nil)
        XCTAssertEqual(outcome, .closedNormally)
        XCTAssertEqual(outcome.severity, .info)
    }
}
