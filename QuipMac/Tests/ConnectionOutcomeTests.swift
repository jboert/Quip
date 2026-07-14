import XCTest
@testable import Quip

final class ConnectionOutcomeTests: XCTestCase {

    /// The exact shape of a LatencyProbeService probe: TCP connects, the WS
    /// handshake never completes (never reaches .ready), then the connection is
    /// cancelled with no error. This MUST NOT be reported as a failure — doing
    /// so cost a full debugging session chasing a dual-backend bug that did not
    /// exist.
    func test_probeThatNeverHandshook_isBenign_notAFailure() {
        let outcome = ConnectionOutcome.classify(reachedReady: false, error: nil)
        XCTAssertEqual(outcome, .abortedHandshake)
        XCTAssertEqual(outcome.severity, .info)
        XCTAssertFalse(outcome.describe(endpoint: "192.168.4.34:56767").uppercased().contains("FAILED"))
    }

    /// The other half of that discriminator, and the one worth guarding hardest:
    /// a dial that ERRORS before .ready — a TLS handshake failure, an ECONNRESET
    /// mid-upgrade — is a real "the phone can't connect" failure. Calling it a
    /// benign probe would be a lie in the exact log a user reads to debug this,
    /// and dropping the NWError would leave them nothing to debug WITH.
    func test_dialThatErrorsBeforeReady_isAFailure_andCarriesTheError() {
        let outcome = ConnectionOutcome.classify(
            reachedReady: false, error: "POSIXErrorCode(rawValue: 54): Connection reset by peer")
        XCTAssertEqual(outcome, .failedHandshake("POSIXErrorCode(rawValue: 54): Connection reset by peer"))
        XCTAssertEqual(outcome.severity, .warn,
                       "a failed handshake must not be filed as routine INFO")
        let line = outcome.describe(endpoint: "192.168.4.34:56767")
        XCTAssertTrue(line.contains("Connection reset by peer"),
                      "the error text must reach the log — a failure with no cause is undebuggable")
        XCTAssertFalse(line.contains("probe"),
                       "must not claim it was a benign probe: nothing here verified that")
    }

    /// A TLS-layer break also dies before .ready, and is likewise not a probe.
    func test_tlsHandshakeFailure_isNotClassifiedAsAProbe() {
        let outcome = ConnectionOutcome.classify(reachedReady: false, error: "tls: handshake failure")
        XCTAssertNotEqual(outcome, .abortedHandshake)
        XCTAssertEqual(outcome.severity, .warn)
        XCTAssertTrue(outcome.describe(endpoint: "100.72.13.19:56736").contains("tls: handshake failure"))
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
