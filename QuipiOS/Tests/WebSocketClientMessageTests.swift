import XCTest
@testable import Quip

/// Feeds wire messages straight into `WebSocketClient.handleMessage` (no
/// socket) and locks two behaviours from the 2026-10-07 simulator QA pass:
/// a successful PIN clears an earlier "Auth failed" (US-004), and a
/// preference restore addressed to another device is not applied (US-014).
@MainActor
final class WebSocketClientMessageTests: XCTestCase {

    private func feed(_ client: WebSocketClient, _ json: String) {
        client.handleMessage(Data(json.utf8))
    }

    // MARK: - US-004: "Auth failed" clears once authentication succeeds

    func test_rejectedPIN_recordsAuthFailed() {
        let client = WebSocketClient()

        feed(client, #"{"type":"auth_result","success":false,"error":"Incorrect PIN"}"#)

        XCTAssertFalse(client.isAuthenticated)
        XCTAssertEqual(client.authError, "Incorrect PIN")
        XCTAssertEqual(client.lastError, "Auth failed: Incorrect PIN")
        guard case .authFailed(let message)? = client.lastDisconnectReason else {
            return XCTFail("a rejected PIN must record .authFailed")
        }
        XCTAssertEqual(message, "Incorrect PIN")
    }

    func test_authSuccess_clearsTheEarlierAuthFailure() {
        let client = WebSocketClient()
        feed(client, #"{"type":"auth_result","success":false,"error":"Incorrect PIN"}"#)

        feed(client, #"{"type":"auth_result","success":true}"#)

        XCTAssertTrue(client.isAuthenticated)
        XCTAssertNil(client.authError)
        XCTAssertNil(client.lastError,
                     "the red 'Auth failed' text must not stay next to 'Connected'")
        XCTAssertNil(client.lastDisconnectReason)
    }

    func test_authSuccess_keepsAReasonOfAnotherKind() {
        let client = WebSocketClient()
        client.lastDisconnectReason = .stalled(seconds: 25)

        feed(client, #"{"type":"auth_result","success":true}"#)

        XCTAssertNil(client.lastError)
        guard case .stalled(let seconds)? = client.lastDisconnectReason else {
            return XCTFail("only .authFailed is cleared by a successful auth; the diagnostics sheet reads the rest")
        }
        XCTAssertEqual(seconds, 25)
    }

    // MARK: - US-014: a restore for another device is not applied

    func test_restoreIsForThisDevice() {
        XCTAssertTrue(WebSocketClient.restoreIsForThisDevice(nil, own: "A"),
                      "an older Mac names no device; apply as before")
        XCTAssertTrue(WebSocketClient.restoreIsForThisDevice("A", own: "A"))
        XCTAssertFalse(WebSocketClient.restoreIsForThisDevice("B", own: "A"))
    }

    func test_preferencesRestore_appliesOnlyWhenAddressedHereOrUnaddressed() {
        let client = WebSocketClient()
        client.isAuthenticated = true
        var applied = 0
        client.onPreferencesRestore = { _ in applied += 1 }

        feed(client, #"{"type":"preferences_restore","deviceID":"\#(UUID().uuidString)","preferences":{"ttsEnabled":true}}"#)
        XCTAssertEqual(applied, 0, "another device's settings must never land here")

        feed(client, #"{"type":"preferences_restore","preferences":{"ttsEnabled":true}}"#)
        XCTAssertEqual(applied, 1, "a restore with no device id (older Mac) is applied as before")

        feed(client, #"{"type":"preferences_restore","deviceID":"\#(KeychainDeviceID.get())","preferences":{"ttsEnabled":true}}"#)
        XCTAssertEqual(applied, 2, "a restore addressed to this device is applied")
    }

    func test_preferencesRestore_requiresAuthentication() {
        let client = WebSocketClient()
        var applied = 0
        client.onPreferencesRestore = { _ in applied += 1 }

        feed(client, #"{"type":"preferences_restore","preferences":{"ttsEnabled":true}}"#)

        XCTAssertEqual(applied, 0)
    }
}
