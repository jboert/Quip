//! The WebSocket server (tokio-tungstenite), started from QuipLinux's
//! `ws_server.rs` and brought to the Mac's behaviour
//! (`QuipMac/Services/WebSocketServer.swift`):
//!
//! 1. TCP accepted, if fewer than `MAX_UNAUTHENTICATED` sockets are waiting
//!    for auth (more are closed at once). A socket that has not finished the
//!    WebSocket upgrade within `PRE_HANDSHAKE_DEADLINE` (10 s, the Mac's
//!    `PreHandshakeReapPolicy`) is closed, and one that has not authenticated
//!    within `PRE_AUTH_DEADLINE` (120 s, long enough to type a PIN on the
//!    phone's prompt) of its accept is closed too, so a peer that upgrades and
//!    never sends a right PIN cannot hold a socket forever.
//! 2. On upgrade the host sends `auth_result {success:false, error:"auth_required"}`;
//!    the 1.6.0 phone sends its PIN only after that (spec 3.1 omits it).
//! 3. Before auth every frame except `auth` is dropped, with no reply.
//! 4. Right PIN: `auth_result`, `device_identity`, `layout_update`, in that
//!    order (then `frontmost_changed` when the foreground is tracked).
//! 5. Unknown types and bad JSON are logged and ignored; a frame over
//!    `MAX_MESSAGE_BYTES` is dropped and logged. None closes the socket.
//! 6. Every frame except `auth` counts against `RateLimit` (the Mac's
//!    `ClientConnection.allowMessage`: 10 per second per client); the rest of
//!    the second's frames are dropped, logged once per window.
//!
//! Each connection has a reader (this task, messages handled in order, so a
//! `send_text` followed by `press_return` cannot overtake each other) and a
//! writer task fed by a bounded queue.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

use crate::host::{Host, Ticks, HEARTBEAT_INTERVAL, POLL_INTERVAL};
use crate::protocol::limits::{MAX_MESSAGE_BYTES, PROTOCOL_MAX_MESSAGE_BYTES};
use crate::protocol::messages::{decode_incoming, message_type, AuthMessage, DecodeError, Incoming};
use crate::services::auth_throttle::AuthThrottle;
use crate::services::quip_log::Severity;

/// `WebSocketServer.listenPort`: a constant, not a setting the phone could
/// be told about wrongly (`ListenPortTests`).
pub const LISTEN_PORT: u16 = 8765;
/// `PreHandshakeReapPolicy.deadline`.
pub const PRE_HANDSHAKE_DEADLINE: Duration = Duration::from_secs(10);
/// A send that takes longer than this means the phone is gone.
pub const WRITE_TIMEOUT: Duration = Duration::from_secs(10);
/// `ClientConnection.maxMessagesPerSecond`.
pub const MAX_MESSAGES_PER_SECOND: u32 = 10;

/// `ClientConnection.allowMessage`: a fixed one-second window that starts at
/// the first message after the previous window ended. `now` is the host's
/// monotonic clock.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RateLimit {
    window_start: Option<Duration>,
    count: u32,
}

impl RateLimit {
    pub const fn new() -> Self {
        Self { window_start: None, count: 0 }
    }

    pub fn allow(&mut self, now: Duration) -> bool {
        match self.window_start {
            Some(start) if now.saturating_sub(start) < Duration::from_secs(1) => {
                self.count += 1;
                self.count <= MAX_MESSAGES_PER_SECOND
            }
            _ => {
                self.window_start = Some(now);
                self.count = 1;
                true
            }
        }
    }
}

impl Default for RateLimit {
    fn default() -> Self {
        Self::new()
    }
}

/// `PreHandshakeReapPolicy.shouldReap`.
pub fn should_reap(reached_ready: bool) -> bool {
    !reached_ready
}

/// `ConnectionOutcome` (`QuipMac/Services/ConnectionOutcome.swift`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionOutcome {
    AbortedHandshake,
    FailedHandshake(String),
    ClosedNormally,
    Failed(String),
}

impl ConnectionOutcome {
    pub fn classify(reached_ready: bool, error: Option<String>) -> Self {
        match (reached_ready, error) {
            (false, None) => ConnectionOutcome::AbortedHandshake,
            (false, Some(e)) => ConnectionOutcome::FailedHandshake(e),
            (true, None) => ConnectionOutcome::ClosedNormally,
            (true, Some(e)) => ConnectionOutcome::Failed(e),
        }
    }

    pub fn severity(&self) -> Severity {
        match self {
            ConnectionOutcome::AbortedHandshake | ConnectionOutcome::ClosedNormally => Severity::Info,
            ConnectionOutcome::FailedHandshake(_) => Severity::Warn,
            ConnectionOutcome::Failed(_) => Severity::Error,
        }
    }

    pub fn describe(&self, endpoint: &str) -> String {
        match self {
            ConnectionOutcome::AbortedHandshake => {
                format!("connection from {endpoint} closed before handshake (probe or abandoned dial)")
            }
            ConnectionOutcome::FailedHandshake(e) => {
                format!("connection from {endpoint} broke during handshake — the client never got connected: {e}")
            }
            ConnectionOutcome::ClosedNormally => format!("connection from {endpoint} closed"),
            ConnectionOutcome::Failed(e) => format!("established connection from {endpoint} failed: {e}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BindError {
    /// Something already listens there (another Quip?). The tray shows it.
    PortInUse(u16),
    /// `--fake-platform` refuses the real app's port.
    RefusedPort(u16, &'static str),
    Other(String),
}

impl std::fmt::Display for BindError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BindError::PortInUse(p) => write!(f, "Port {p} is already in use (is another Quip running?)"),
            BindError::RefusedPort(p, why) => write!(f, "Port {p} refused: {why}"),
            BindError::Other(e) => write!(f, "Could not listen: {e}"),
        }
    }
}

pub async fn bind(addr: SocketAddr) -> Result<TcpListener, BindError> {
    TcpListener::bind(addr).await.map_err(|e| {
        if e.kind() == std::io::ErrorKind::AddrInUse {
            BindError::PortInUse(addr.port())
        } else {
            BindError::Other(e.to_string())
        }
    })
}

fn ws_config() -> WebSocketConfig {
    WebSocketConfig {
        max_message_size: Some(PROTOCOL_MAX_MESSAGE_BYTES),
        max_frame_size: Some(PROTOCOL_MAX_MESSAGE_BYTES),
        ..Default::default()
    }
}

/// Accept forever. Also starts the heartbeat and poll timers when the host
/// uses `Ticks::Auto`.
pub fn spawn(host: Arc<Host>, listener: TcpListener) -> JoinHandle<()> {
    if host.config.ticks == Ticks::Auto {
        let h = host.clone();
        tokio::spawn(async move {
            let mut t = tokio::time::interval(HEARTBEAT_INTERVAL);
            t.tick().await; // the first tick is immediate; the phone just got auth
            loop {
                t.tick().await;
                h.heartbeat_tick();
            }
        });
        let h = host.clone();
        tokio::spawn(async move {
            let mut t = tokio::time::interval(POLL_INTERVAL);
            t.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                t.tick().await;
                h.poll_tick().await;
            }
        });
    }
    if let Ok(a) = listener.local_addr() {
        host.logs.ws(Severity::Info, &format!("listening on {a}"));
    }
    tokio::spawn(async move {
        let mut refused: u64 = 0;
        loop {
            match listener.accept().await {
                Ok((stream, peer)) => {
                    let Some(slot) = host.try_pre_auth_slot() else {
                        refused += 1;
                        if refused == 1 || refused.is_multiple_of(100) {
                            host.logs.ws(
                                Severity::Warn,
                                &format!(
                                    "refused {peer}: {} sockets already waiting for auth (refused={refused})",
                                    host.config.limits.max_unauthenticated
                                ),
                            );
                        }
                        drop(stream);
                        continue;
                    };
                    let h = host.clone();
                    tokio::spawn(async move { connection(h, stream, peer, slot).await });
                }
                Err(e) => {
                    host.logs.ws(Severity::Warn, &format!("accept failed: {e}"));
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
        }
    })
}

fn is_benign_close(e: &WsError) -> bool {
    match e {
        WsError::ConnectionClosed | WsError::AlreadyClosed => true,
        WsError::Io(io) => matches!(
            io.kind(),
            std::io::ErrorKind::UnexpectedEof | std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::BrokenPipe
        ),
        WsError::Protocol(p) => p.to_string().contains("without closing handshake"),
        _ => false,
    }
}

async fn connection(host: Arc<Host>, stream: TcpStream, peer: SocketAddr, slot: crate::host::PreAuthSlot) {
    let remote = peer.to_string();
    if host.config.loopback_only && !peer.ip().is_loopback() {
        host.logs.ws(Severity::Warn, &format!("refused non-loopback peer {remote} (fake platform is 127.0.0.1 only)"));
        return;
    }
    let _ = stream.set_nodelay(true);
    let auth_deadline = host.config.limits.pre_auth_deadline;
    let deadline = tokio::time::Instant::now() + auth_deadline;
    let handshake_deadline = tokio::time::Instant::now() + PRE_HANDSHAKE_DEADLINE.min(auth_deadline);
    let ws = match tokio::time::timeout_at(
        handshake_deadline,
        tokio_tungstenite::accept_async_with_config(stream, Some(ws_config())),
    )
    .await
    {
        Err(_) => {
            if should_reap(false) {
                host.logs.ws(
                    Severity::Info,
                    &format!(
                        "reaped {remote}: no WebSocket upgrade within {}ms",
                        PRE_HANDSHAKE_DEADLINE.min(auth_deadline).as_millis()
                    ),
                );
            }
            return;
        }
        Ok(Err(e)) => {
            let err = if is_benign_close(&e) { None } else { Some(e.to_string()) };
            let o = ConnectionOutcome::classify(false, err);
            host.logs.ws(o.severity(), &o.describe(&remote));
            return;
        }
        Ok(Ok(ws)) => ws,
    };
    let (mut sink, mut source) = ws.split();
    let (id, mut rx) = host.register_client(remote.clone());
    host.logs.ws(Severity::Info, &format!("connection ready from {remote} — awaiting PIN"));
    let writer = tokio::spawn(async move {
        while let Some(json) = rx.recv().await {
            match tokio::time::timeout(WRITE_TIMEOUT, sink.send(Message::Text(json))).await {
                Ok(Ok(())) => {}
                _ => break,
            }
        }
        let _ = sink.close().await;
    });
    host.greet(id);
    let throttle_host = AuthThrottle::host(&remote);
    let mut error: Option<String> = None;
    let mut slot = Some(slot);
    let mut rate = RateLimit::new();
    let mut rate_dropping = false;
    loop {
        let next = if slot.is_some() {
            match tokio::time::timeout_at(deadline, source.next()).await {
                Ok(n) => n,
                Err(_) => {
                    host.logs.ws(
                        Severity::Warn,
                        &format!("reaped {remote}: not authenticated within {}ms", auth_deadline.as_millis()),
                    );
                    break;
                }
            }
        } else {
            source.next().await
        };
        let Some(frame) = next else { break };
        let text = match frame {
            Ok(Message::Text(t)) => t,
            // The Mac parses binary frames as JSON too.
            Ok(Message::Binary(b)) => match String::from_utf8(b) {
                Ok(t) => t,
                Err(_) => {
                    host.logs.ws(Severity::Warn, &format!("ignored non-UTF-8 binary frame from {remote}"));
                    continue;
                }
            },
            Ok(Message::Close(_)) => break,
            Ok(_) => continue, // ping/pong: tungstenite answers pings itself
            Err(e) => {
                if !is_benign_close(&e) {
                    error = Some(e.to_string());
                }
                break;
            }
        };
        if text.len() > MAX_MESSAGE_BYTES {
            host.logs.ws(Severity::Warn, &format!("drop_oversized bytes={} from {remote}", text.len()));
            continue;
        }
        let received = host.clock.monotonic();
        let is_auth = message_type(&text).as_deref() == Some("auth");
        if !host.is_authenticated(id) {
            if is_auth {
                let pin = serde_json::from_str::<AuthMessage>(&text).ok().map(|a| a.pin);
                host.handle_auth(id, &throttle_host, pin).await;
                if host.is_authenticated(id) {
                    slot = None; // frees the pre-auth slot, lifts the deadline
                }
            } else {
                host.logs.debug(&format!("dropped pre-auth frame from {remote}"));
            }
            continue;
        }
        // Auth frames bypass the limit, as on the Mac.
        if !is_auth {
            if !rate.allow(received) {
                if !rate_dropping {
                    rate_dropping = true;
                    host.logs.ws(
                        Severity::Warn,
                        &format!("rate limit: dropping frames from {remote} over {MAX_MESSAGES_PER_SECOND}/s"),
                    );
                }
                continue;
            }
            rate_dropping = false;
        }
        match decode_incoming(&text) {
            Ok(Incoming::Auth(a)) => host.handle_auth(id, &throttle_host, Some(a.pin)).await,
            Ok(Incoming::HeartbeatAck(a)) => host.heartbeat_ack(id, &a),
            Ok(msg) => host.route(id, msg, received).await,
            Err(DecodeError::Unknown(t)) => host.logs.debug(&format!("ignored type={t}")),
            Err(DecodeError::BadJson) => {
                host.logs.ws(Severity::Warn, &format!("ignored undecodable frame bytes={} from {remote}", text.len()))
            }
            Err(DecodeError::BadPayload { type_, error }) => {
                host.logs.ws(Severity::Warn, &format!("ignored {type_}: decode failed: {error}"))
            }
        }
    }
    // Dropping the client's queue ends the writer after it has sent what is
    // queued, and it closes the socket with a Close frame. A writer stuck on
    // a dead peer is cut off.
    host.remove_client(id);
    let mut writer = writer;
    if tokio::time::timeout(Duration::from_secs(1), &mut writer).await.is_err() {
        writer.abort();
    }
    let o = ConnectionOutcome::classify(true, error);
    host.logs.ws(o.severity(), &o.describe(&remote));
}

#[cfg(test)]
mod tests {
    //! `PreHandshakeReapPolicyTests`, `ConnectionOutcomeTests`, `ListenPortTests`.
    #![allow(non_snake_case)]
    use super::*;

    #[test]
    fn test_connectionThatNeverHandshook_isReaped() {
        assert!(should_reap(false));
    }

    #[test]
    fn test_establishedConnection_isNeverReaped() {
        assert!(!should_reap(true));
    }

    #[test]
    fn test_deadlineBeatsThePeersFinWait2Rst() {
        assert!(PRE_HANDSHAKE_DEADLINE < Duration::from_secs(60));
    }

    #[test]
    fn test_deadlineLeavesRoomForASlowButRealHandshake() {
        assert!(PRE_HANDSHAKE_DEADLINE >= Duration::from_secs(5));
    }

    #[test]
    fn test_probeThatNeverHandshook_isBenign_notAFailure() {
        let o = ConnectionOutcome::classify(false, None);
        assert_eq!(o, ConnectionOutcome::AbortedHandshake);
        assert_eq!(o.severity(), Severity::Info);
        assert!(!o.describe("192.168.1.134:56767").to_uppercase().contains("FAILED"));
    }

    #[test]
    fn test_dialThatErrorsBeforeReady_isAFailure_andCarriesTheError() {
        let e = "Connection reset by peer".to_string();
        let o = ConnectionOutcome::classify(false, Some(e.clone()));
        assert_eq!(o, ConnectionOutcome::FailedHandshake(e));
        assert_eq!(o.severity(), Severity::Warn);
        let l = o.describe("x:1");
        assert!(l.contains("Connection reset by peer"));
        assert!(!l.contains("probe"));
    }

    #[test]
    fn test_tlsHandshakeFailure_isNotClassifiedAsAProbe() {
        let o = ConnectionOutcome::classify(false, Some("tls: handshake failure".into()));
        assert_ne!(o, ConnectionOutcome::AbortedHandshake);
        assert_eq!(o.severity(), Severity::Warn);
    }

    #[test]
    fn test_establishedSocketThatDies_isAFailure() {
        let o = ConnectionOutcome::classify(true, Some("reset by peer".into()));
        assert_eq!(o, ConnectionOutcome::Failed("reset by peer".into()));
        assert_eq!(o.severity(), Severity::Error);
        assert!(o.describe("x").contains("reset by peer"));
    }

    #[test]
    fn test_establishedSocketClosedCleanly_isBenign() {
        let o = ConnectionOutcome::classify(true, None);
        assert_eq!(o, ConnectionOutcome::ClosedNormally);
        assert_eq!(o.severity(), Severity::Info);
    }

    // `ClientConnection.allowMessage` (no Mac test file; same numbers).
    #[test]
    fn rate_limit_allows_ten_per_second_then_drops() {
        let mut r = RateLimit::new();
        let t = Duration::from_secs(100);
        for i in 0..10 {
            assert!(r.allow(t + Duration::from_millis(i * 10)), "message {i}");
        }
        assert!(!r.allow(t + Duration::from_millis(500)));
        assert!(!r.allow(t + Duration::from_millis(999)));
        assert!(r.allow(t + Duration::from_secs(1)), "a new window at exactly 1 s");
        for _ in 0..9 {
            assert!(r.allow(t + Duration::from_secs(1)));
        }
        assert!(!r.allow(t + Duration::from_secs(1)));
    }

    #[test]
    fn rate_limit_window_starts_at_the_first_message_after_a_gap() {
        let mut r = RateLimit::default();
        assert!(r.allow(Duration::from_millis(0)));
        assert!(r.allow(Duration::from_millis(5_000)), "new window");
        for _ in 0..9 {
            assert!(r.allow(Duration::from_millis(5_900)));
        }
        assert!(!r.allow(Duration::from_millis(5_999)));
        assert_eq!(MAX_MESSAGES_PER_SECOND, 10);
    }

    #[test]
    fn pre_auth_limits_match_the_mac() {
        // The upgrade deadline is the Mac's; the auth deadline must leave time
        // to type a PIN on the phone's prompt.
        assert_eq!(PRE_HANDSHAKE_DEADLINE, Duration::from_secs(10));
        assert!(crate::host::PRE_AUTH_DEADLINE >= Duration::from_secs(60));
        assert_eq!(crate::host::MAX_UNAUTHENTICATED, 16);
    }

    #[test]
    fn test_listenPort_is8765() {
        assert_eq!(LISTEN_PORT, 8765);
    }

    #[tokio::test]
    async fn port_in_use_is_a_clear_error() {
        let first = bind("127.0.0.1:0".parse().unwrap()).await.unwrap();
        let addr = first.local_addr().unwrap();
        let err = bind(addr).await.unwrap_err();
        assert_eq!(err, BindError::PortInUse(addr.port()));
        assert!(err.to_string().contains("already in use"));
    }
}
