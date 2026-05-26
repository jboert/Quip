import XCTest
@testable import Quip

/// Locks the NWPathMonitor reconnect-kick predicate so a path-update burst
/// during an in-flight handshake can't tear the in-flight socket down and
/// spawn a fresh one. Three rapid `.satisfied` events during `isConnecting`
/// were producing the daily 2-8-socket reconnect storm visible Mac-side as
/// repeated `POSIX 57 ENOTCONN` failures (558 occurrences over 10 days,
/// almost always in bursts of 2-8 — exact signature of path-update bursts).
///
/// The fix is a one-line guard `!isConnecting` in `pathUpdateHandler`. The
/// `startStuckWatchdog` (5s tick, `stuckThresholdSec` deadline) already
/// covers the "in-flight handshake actually wedged" case, so refusing to
/// preempt an in-flight attempt loses nothing — at worst we wait the 8s
/// connection-timeout + one watchdog tick on a true Wi-Fi → cellular
/// handoff during isConnecting.
final class PathDrivenReconnectGuardTests: XCTestCase {

    func test_kicks_whenNotConnectedAndIdle() {
        XCTAssertTrue(WebSocketClient.shouldKickReconnect(
            isConnected: false, isConnecting: false,
            intentional: false, hasServerURL: true))
    }

    func test_doesNotKick_whenAlreadyConnected() {
        XCTAssertFalse(WebSocketClient.shouldKickReconnect(
            isConnected: true, isConnecting: false,
            intentional: false, hasServerURL: true))
    }

    /// THE FIX: a `.satisfied` event mid-handshake must NOT tear down the
    /// in-flight attempt and restart. Previously this guard was missing,
    /// causing the storm.
    func test_doesNotKick_whileHandshakeInFlight() {
        XCTAssertFalse(WebSocketClient.shouldKickReconnect(
            isConnected: false, isConnecting: true,
            intentional: false, hasServerURL: true))
    }

    func test_doesNotKick_whenUserIntentionallyDisconnected() {
        XCTAssertFalse(WebSocketClient.shouldKickReconnect(
            isConnected: false, isConnecting: false,
            intentional: true, hasServerURL: true))
    }

    func test_doesNotKick_whenNoServerURL() {
        XCTAssertFalse(WebSocketClient.shouldKickReconnect(
            isConnected: false, isConnecting: false,
            intentional: false, hasServerURL: false))
    }
}
