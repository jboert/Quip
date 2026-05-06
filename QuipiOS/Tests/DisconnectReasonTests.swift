import XCTest
@testable import Quip

/// Locks the rendered label + topBarStatus mapping for every
/// DisconnectReason case. Renames here ripple — callers grep the
/// label tokens (§B17 trace pipeline) and the §K pill maps the
/// topBarStatus directly into UI state.
final class DisconnectReasonTests: XCTestCase {

    // MARK: - label

    func testUserInitiatedLabel() {
        XCTAssertEqual(DisconnectReason.userInitiated.label, "Disconnected")
    }

    func testTimedOutLabel() {
        XCTAssertEqual(DisconnectReason.timedOut.label, "Connection timed out")
    }

    func testStalledLabelIncludesSeconds() {
        XCTAssertEqual(DisconnectReason.stalled(seconds: 26).label, "Stalled 26s — resetting")
        XCTAssertEqual(DisconnectReason.stalled(seconds: 0).label, "Stalled 0s — resetting")
    }

    func testAuthFailedLabelWithoutMessage() {
        XCTAssertEqual(DisconnectReason.authFailed(message: nil).label, "Auth failed")
        XCTAssertEqual(DisconnectReason.authFailed(message: "").label, "Auth failed")
    }

    func testAuthFailedLabelWithMessage() {
        XCTAssertEqual(DisconnectReason.authFailed(message: "Wrong PIN").label, "Auth failed: Wrong PIN")
        XCTAssertEqual(DisconnectReason.authFailed(message: "PIN throttled — try again in 30s").label,
                       "Auth failed: PIN throttled — try again in 30s")
    }

    func testNetworkErrorLabelPassesThroughVerbatim() {
        XCTAssertEqual(DisconnectReason.networkError("The Internet connection appears to be offline.").label,
                       "The Internet connection appears to be offline.")
        XCTAssertEqual(DisconnectReason.networkError("No pong (2/2)").label, "No pong (2/2)")
    }

    func testServerClosedLabel() {
        XCTAssertEqual(DisconnectReason.serverClosed.label, "Server closed connection")
    }

    func testUnknownLabel() {
        XCTAssertEqual(DisconnectReason.unknown.label, "Disconnected")
    }

    // MARK: - topBarStatus mapping

    func testAuthFailedMapsToAuthFailedPill() {
        XCTAssertEqual(DisconnectReason.authFailed(message: nil).topBarStatus, .authFailed)
        XCTAssertEqual(DisconnectReason.authFailed(message: "Wrong PIN").topBarStatus, .authFailed)
    }

    func testStalledMapsToStalledPill() {
        XCTAssertEqual(DisconnectReason.stalled(seconds: 30).topBarStatus, .stalled)
    }

    func testTimedOutMapsToStalledPill() {
        XCTAssertEqual(DisconnectReason.timedOut.topBarStatus, .stalled)
    }

    func testNetworkErrorMapsToStalledPill() {
        XCTAssertEqual(DisconnectReason.networkError("anything").topBarStatus, .stalled)
    }

    func testServerClosedMapsToStalledPill() {
        XCTAssertEqual(DisconnectReason.serverClosed.topBarStatus, .stalled)
    }

    func testUnknownMapsToStalledPill() {
        XCTAssertEqual(DisconnectReason.unknown.topBarStatus, .stalled)
    }

    func testUserInitiatedMapsToNilSoCallerDecides() {
        XCTAssertNil(DisconnectReason.userInitiated.topBarStatus,
                     "userInitiated leaves the pill state to the caller (unpaired vs stalled)")
    }

    // MARK: - tag (diagnostics-friendly)

    func testTagIsBareCaseName() {
        XCTAssertEqual(DisconnectReason.userInitiated.tag, "userInitiated")
        XCTAssertEqual(DisconnectReason.timedOut.tag, "timedOut")
        XCTAssertEqual(DisconnectReason.stalled(seconds: 99).tag, "stalled")
        XCTAssertEqual(DisconnectReason.authFailed(message: "x").tag, "authFailed")
        XCTAssertEqual(DisconnectReason.networkError("x").tag, "networkError")
        XCTAssertEqual(DisconnectReason.serverClosed.tag, "serverClosed")
        XCTAssertEqual(DisconnectReason.unknown.tag, "unknown")
    }

    // MARK: - equality

    func testEqualityIgnoresAssociatedValueDifferences() {
        XCTAssertEqual(DisconnectReason.timedOut, DisconnectReason.timedOut)
        XCTAssertEqual(DisconnectReason.stalled(seconds: 5), DisconnectReason.stalled(seconds: 5))
        XCTAssertNotEqual(DisconnectReason.stalled(seconds: 5), DisconnectReason.stalled(seconds: 6))
        XCTAssertEqual(DisconnectReason.authFailed(message: "x"), DisconnectReason.authFailed(message: "x"))
        XCTAssertNotEqual(DisconnectReason.authFailed(message: "x"), DisconnectReason.authFailed(message: "y"))
        XCTAssertNotEqual(DisconnectReason.timedOut, DisconnectReason.serverClosed)
    }
}

/// Locks the new reason-based TopBarStatus.classify overload.
/// The legacy lastError-based overload has its own coverage in
/// TopBarStatusTests.
final class TopBarStatusReasonClassifierTests: XCTestCase {

    func testConnectedWinsRegardlessOfReason() {
        // Even with a stale "auth failed" reason, an active WS = green.
        XCTAssertEqual(TopBarStatus.classify(isConnected: true,
                                             isConnecting: false,
                                             isAuthenticated: true,
                                             reason: .authFailed(message: "Wrong PIN"),
                                             hasPaired: true),
                       .connected)
    }

    func testNoPairedReturnsUnpaired() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                             isConnecting: false,
                                             isAuthenticated: false,
                                             reason: .timedOut,
                                             hasPaired: false),
                       .unpaired)
    }

    func testAuthFailedReasonReturnsAuthFailedPill() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                             isConnecting: false,
                                             isAuthenticated: false,
                                             reason: .authFailed(message: nil),
                                             hasPaired: true),
                       .authFailed)
    }

    func testStalledReasonReturnsStalledPill() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                             isConnecting: true,
                                             isAuthenticated: false,
                                             reason: .stalled(seconds: 30),
                                             hasPaired: true),
                       .stalled,
                       "stalled reason outranks isConnecting=true so user sees something's wrong")
    }

    func testTimedOutReasonReturnsStalledPill() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                             isConnecting: false,
                                             isAuthenticated: false,
                                             reason: .timedOut,
                                             hasPaired: true),
                       .stalled)
    }

    func testNetworkErrorReasonReturnsStalledPill() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                             isConnecting: false,
                                             isAuthenticated: false,
                                             reason: .networkError("offline"),
                                             hasPaired: true),
                       .stalled)
    }

    func testNilReasonWhileConnectingFallsBackToConnecting() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                             isConnecting: true,
                                             isAuthenticated: false,
                                             reason: nil,
                                             hasPaired: true),
                       .connecting)
    }

    func testNilReasonNotConnectingFallsBackToStalled() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                             isConnecting: false,
                                             isAuthenticated: false,
                                             reason: nil,
                                             hasPaired: true),
                       .stalled)
    }

    func testUserInitiatedReasonFallsThroughToConnectingOrStalled() {
        // userInitiated has no topBarStatus mapping — falls through to
        // the same logic as nil reason.
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                             isConnecting: true,
                                             isAuthenticated: false,
                                             reason: .userInitiated,
                                             hasPaired: true),
                       .connecting)
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                             isConnecting: false,
                                             isAuthenticated: false,
                                             reason: .userInitiated,
                                             hasPaired: true),
                       .stalled)
    }
}
