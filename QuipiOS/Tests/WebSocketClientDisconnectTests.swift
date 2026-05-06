import XCTest
@testable import Quip

/// Locks the post-disconnect state of `WebSocketClient` so the
/// "Stalled 26s — resetting" lastError can't linger after the user
/// forgets a backend or explicitly disconnects.
/// (Bug #1 from continuation-3 sim QA pass.)
@MainActor
final class WebSocketClientDisconnectTests: XCTestCase {

    func test_disconnect_clearsLastError() {
        let client = WebSocketClient()
        // Simulate a watchdog-set error from a previous connect attempt.
        client.lastError = "Stalled 26s — resetting"

        client.disconnect()

        XCTAssertNil(client.lastError,
                     "Bug #1 — disconnect must clear lastError so the picker's empty-state UI doesn't show a stale watchdog message")
    }

    func test_disconnect_resetsConnectionFlags() {
        let client = WebSocketClient()
        client.isConnecting = true

        client.disconnect()

        XCTAssertFalse(client.isConnecting)
        XCTAssertFalse(client.isConnected)
        XCTAssertFalse(client.isAuthenticated)
    }

    func test_disconnect_isIdempotent() {
        let client = WebSocketClient()
        client.disconnect()
        client.disconnect()
        XCTAssertNil(client.lastError)
        XCTAssertFalse(client.isConnecting)
    }
}
