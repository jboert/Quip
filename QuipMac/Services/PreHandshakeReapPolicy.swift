import Foundation

/// When to give up on an accepted TCP connection that never became a WebSocket.
///
/// The listener accepts TCP long before the HTTP upgrade arrives, and nothing
/// used to bound the wait. A peer that connects and then walks away therefore
/// pinned a Mac-side socket forever — measured in CLOSE_WAIT four minutes after
/// the peer's FIN, and it would have stayed there.
///
/// The phone does exactly that on purpose: `LatencyProbeService` opens a
/// TCP-only probe to each alternate URL every 60s and closes it the moment TCP
/// is up, deliberately never handshaking. So the leak was one socket per alt
/// URL per minute, all day.
///
/// The second-order effect is what actually cost debugging time. The peer's own
/// FIN_WAIT_2 idle timer eventually abandons the half-closed socket and sends an
/// RST. Because the Mac's connection was still alive to receive it, that landed
/// as `.failed(ECONNRESET)` and websocket.log recorded
/// "broke during handshake — the client never got connected" at WARN, roughly a
/// minute after each probe — a line that reads precisely like "the phone cannot
/// reach the Mac on this path", for a path that was healthy. Reaping first turns
/// that into a cancel we initiated and can describe honestly.
enum PreHandshakeReapPolicy {

    /// How long an accepted connection may stay pre-handshake before we close
    /// it.
    ///
    /// Bounded on both sides. It must be well under the peer's ~60s FIN_WAIT_2
    /// timeout, or the spurious WARN is already logged by the time we act. It
    /// must also clear a genuine handshake by a wide margin — a real dial
    /// completes TCP + upgrade in milliseconds, so seconds of headroom covers a
    /// badly degraded link without ever being the reason a client fails to
    /// connect.
    static let deadline: TimeInterval = 10

    /// Pure decision, evaluated when the deadline fires: close this connection?
    ///
    /// Keyed solely on whether the WebSocket handshake completed. An
    /// established client is never reaped no matter how idle — idle established
    /// sockets are the heartbeat timer's business, not this policy's.
    static func shouldReap(reachedReady: Bool) -> Bool {
        !reachedReady
    }
}
