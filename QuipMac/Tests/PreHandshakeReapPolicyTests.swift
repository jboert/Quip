import XCTest
@testable import Quip

/// A TCP connection that never sends a WebSocket upgrade used to live forever
/// on the Mac. `LatencyProbeService` on the phone opens exactly that — a
/// TCP-only probe to every alternate URL, every 60s — and closes it gracefully
/// the instant TCP is up. The Mac kept its half of the socket in CLOSE_WAIT
/// (measured: still CLOSE_WAIT four minutes after the peer's FIN), because
/// nothing on the accept path ever reaps a connection that fails to handshake.
///
/// That leak is what produced the "LAN keeps flapping" symptom. It is not a
/// connectivity fault at all: the peer's own FIN_WAIT_2 idle timer eventually
/// gives up on the half-closed socket and sends an RST, ~60s after the probe.
/// The Mac's connection object is STILL ALIVE to receive it, so it surfaces as
/// `.failed(ECONNRESET)` and websocket.log prints
/// "broke during handshake — the client never got connected" at WARN — a line
/// that reads exactly like "your phone cannot reach the Mac over LAN". 43 of
/// them in one day, describing a LAN path that was working the whole time.
///
/// Reaping the connection before that window closes fixes both halves: no
/// leaked socket, and the RST lands on an already-cancelled connection instead
/// of being reported as a failed dial.
final class PreHandshakeReapPolicyTests: XCTestCase {

    /// The whole point: a connection that never completed the WS handshake is
    /// reaped rather than held open indefinitely.
    func test_connectionThatNeverHandshook_isReaped() {
        XCTAssertTrue(PreHandshakeReapPolicy.shouldReap(reachedReady: false))
    }

    /// A live client must never be reaped — the deadline governs the handshake
    /// only. An established WebSocket is kept alive by the heartbeat timer and
    /// can legitimately sit idle far longer than this deadline.
    func test_establishedConnection_isNeverReaped() {
        XCTAssertFalse(PreHandshakeReapPolicy.shouldReap(reachedReady: true))
    }

    /// The deadline must fire BEFORE the peer's FIN_WAIT_2 timer RSTs the
    /// half-closed socket, or the reap is pointless: the spurious
    /// "broke during handshake" WARN is already in the log by the time we act.
    /// Measured gap between a probe's dial and its RST on this network: ~61s.
    func test_deadlineBeatsThePeersFinWait2Rst() {
        XCTAssertLessThan(PreHandshakeReapPolicy.deadline, 60,
                          "reaping later than the peer's FIN_WAIT_2 timeout logs the very "
                          + "false-alarm WARN this policy exists to prevent")
    }

    /// ...but not so eager that it kills a real client mid-handshake. A phone
    /// on a slow link still has to finish TCP, TLS where applicable, and the
    /// HTTP upgrade; the observed cost of a genuine handshake is milliseconds,
    /// so seconds of headroom is generous without being useless.
    func test_deadlineLeavesRoomForASlowButRealHandshake() {
        XCTAssertGreaterThanOrEqual(PreHandshakeReapPolicy.deadline, 5,
                                    "a real dial on a slow link must not be reaped as a probe")
    }
}
