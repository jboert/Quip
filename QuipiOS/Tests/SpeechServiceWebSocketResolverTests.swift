import XCTest
@testable import Quip

/// Regression coverage for §B11 — speech.webSocket weak-ref dropped when
/// the placeholder client (created before BackendConnectionManager.bootstrap
/// populated sessions) was released, leaving PTT silently stuck on .local.
///
/// The fix replaces `weak var webSocket` with a resolver closure
/// (`webSocketResolver: () -> WebSocketClient?`) that always returns the
/// current active client at every PTT press. These tests pin the contract
/// so a future "let's go back to weak ref" refactor would fail loudly.
@MainActor
final class SpeechServiceWebSocketResolverTests: XCTestCase {

    func testResolverReturnsCurrentClientAfterSwap() {
        let speech = SpeechService()
        var current: WebSocketClient = WebSocketClient()
        speech.attachWebSocketResolver { current }

        let first = speech.webSocket
        XCTAssertNotNil(first, "resolver must surface the initial client")
        XCTAssertTrue(first === current, "first resolve = first client")

        // Backend swap — resolver now returns a fresh client. The §B11
        // bug was that speech kept a weak ref to the original placeholder,
        // which got nilled on release; the resolver pattern ignores
        // identity entirely and asks the closure each time.
        let replacement = WebSocketClient()
        current = replacement

        let second = speech.webSocket
        XCTAssertNotNil(second, "resolver must NOT cache identity across swaps")
        XCTAssertTrue(second === replacement, "second resolve = swapped client")
    }

    func testWebSocketSurvivesPlaceholderRelease() {
        // Reproduces the original failure timing:
        //   1. setup() runs `speech.attachWebSocketResolver` while
        //      `manager.active.client` still resolves to the placeholder.
        //   2. bootstrap() then creates the real session; `manager.active`
        //      flips to the real client. The placeholder is released.
        //   3. PTT fires. With weak-ref, speech.webSocket was nil here.
        //      With resolver, speech.webSocket returns the real client.
        let speech = SpeechService()
        var activeProvider: () -> WebSocketClient? = {
            // Fresh instance per call simulates a manager that synthesizes
            // a placeholder before bootstrap.
            return WebSocketClient()
        }
        speech.attachWebSocketResolver { activeProvider() }

        // Simulate placeholder release + bootstrap swap.
        let real = WebSocketClient()
        activeProvider = { [weak real] in real }

        // Even though the closure captures `real` weakly, the resolver
        // returns it as long as the test holds `real` strongly. The
        // *important* guarantee: speech doesn't cache a stale identity
        // from before bootstrap.
        XCTAssertTrue(speech.webSocket === real, "PTT-time resolve must hit the real client")
    }

    func testNilResolverProducesNilWebSocket() {
        let speech = SpeechService()
        XCTAssertNil(speech.webSocket, "no resolver = no client; no crash")
    }

    func testLegacyAttachWebSocketStillWorks() {
        // The thin compatibility wrapper around the old API must keep
        // working — anything that calls `speech.attachWebSocket(client)`
        // gets the same resolver semantics for a single client.
        let speech = SpeechService()
        let client = WebSocketClient()
        speech.attachWebSocket(client)
        XCTAssertTrue(speech.webSocket === client)
    }
}
