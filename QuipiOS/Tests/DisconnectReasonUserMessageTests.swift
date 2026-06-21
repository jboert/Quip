import XCTest
@testable import Quip

/// Locks the user-facing semantics of DisconnectReason (userMessage / isRetryable)
/// so the connection banner can render legible, actionable copy.
final class DisconnectReasonUserMessageTests: XCTestCase {

    func testRetryableTransientStates() {
        for r in [DisconnectReason.timedOut, .stalled(seconds: 9),
                  .networkError("dns"), .serverClosed, .unknown] {
            XCTAssertTrue(r.isRetryable, "\(r.tag) should auto-reconnect")
        }
    }

    func testNotRetryableNeedsUser() {
        XCTAssertFalse(DisconnectReason.authFailed(message: "Wrong PIN").isRetryable)
        XCTAssertFalse(DisconnectReason.userInitiated.isRetryable)
    }

    func testAuthFailedUsesServerMessageWhenPresent() {
        let r = DisconnectReason.authFailed(message: "PIN throttled — try again in 30s")
        XCTAssertEqual(r.userMessage, "Couldn't authenticate: PIN throttled — try again in 30s")
    }

    func testAuthFailedFallsBackWhenNoMessage() {
        XCTAssertEqual(DisconnectReason.authFailed(message: nil).userMessage,
                       "Couldn't authenticate — check your PIN.")
        XCTAssertEqual(DisconnectReason.authFailed(message: "").userMessage,
                       "Couldn't authenticate — check your PIN.")
    }

    func testEveryCaseHasNonEmptyUserMessage() {
        let all: [DisconnectReason] = [
            .userInitiated, .timedOut, .stalled(seconds: 1),
            .authFailed(message: nil), .networkError("x"), .serverClosed, .unknown,
        ]
        for r in all { XCTAssertFalse(r.userMessage.isEmpty, "\(r.tag) message empty") }
    }

    func testTransientMessagesSignalRecovery() {
        // Retryable states should read as in-progress (end with an ellipsis),
        // non-retryable as terminal/actionable.
        XCTAssertTrue(DisconnectReason.timedOut.userMessage.hasSuffix("…"))
        XCTAssertFalse(DisconnectReason.userInitiated.userMessage.hasSuffix("…"))
    }
}
