use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use futures_util::sink::SinkExt;
use futures_util::stream::{SplitSink, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Mutex};
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;
use tracing::{error, info, warn};

use crate::protocol::messages::{encode_message, message_type, AuthMessage, AuthResultMessage};
use crate::services::auth_throttle::{AuthDecision, AuthThrottle};
use crate::services::connection_log::{ConnectionEventKind, ConnectionLog};
use crate::services::pin_manager::PINManager;

type WsSink = SplitSink<WebSocketStream<TcpStream>, Message>;

/// Per-connection state including auth status, rate limiting, and write half of the socket.
struct ClientConnection {
    sink: WsSink,
    authenticated: bool,
    message_count: u32,
    window_start: Instant,
}

impl ClientConnection {
    /// Returns true if the message should be processed, false if rate-limited.
    /// Allows max 10 messages per second per client.
    fn allow_message(&mut self) -> bool {
        let now = Instant::now();
        if now.duration_since(self.window_start).as_secs_f64() >= 1.0 {
            self.message_count = 1;
            self.window_start = now;
            true
        } else if self.message_count < 10 {
            self.message_count += 1;
            true
        } else {
            false
        }
    }
}

pub struct WsServer {
    port: u16,
    clients: Arc<Mutex<HashMap<usize, ClientConnection>>>,
    client_count: Arc<AtomicUsize>,
    next_id: Arc<AtomicUsize>,
    message_tx: mpsc::UnboundedSender<String>,
    pin_manager: PINManager,
    require_auth: Arc<AtomicBool>,
    pub connection_log: Arc<ConnectionLog>,
    auth_throttle: Arc<AuthThrottle>,
}

impl WsServer {
    pub fn new(port: u16, message_tx: mpsc::UnboundedSender<String>, pin_manager: PINManager) -> Self {
        Self::with_auth(port, message_tx, pin_manager, true)
    }

    pub fn with_auth(port: u16, message_tx: mpsc::UnboundedSender<String>, pin_manager: PINManager, require_auth: bool) -> Self {
        Self {
            port,
            clients: Arc::new(Mutex::new(HashMap::new())),
            client_count: Arc::new(AtomicUsize::new(0)),
            next_id: Arc::new(AtomicUsize::new(0)),
            message_tx,
            pin_manager,
            require_auth: Arc::new(AtomicBool::new(require_auth)),
            connection_log: ConnectionLog::new(),
            auth_throttle: Arc::new(AuthThrottle::new()),
        }
    }

    /// Update the auth requirement for NEW connections. Existing clients keep
    /// whatever auth state they already had — only incoming handshakes see the new value.
    pub fn set_require_auth(&self, require: bool) {
        self.require_auth.store(require, Ordering::Relaxed);
    }

    pub async fn run(&self) {
        // Bind to all interfaces so phones can reach us over LAN or Tailscale,
        // not just loopback. Auth / PIN gates the actual access.
        let addr = format!("0.0.0.0:{}", self.port);
        let listener = match TcpListener::bind(&addr).await {
            Ok(l) => l,
            Err(e) => {
                error!("Failed to bind WebSocket server on {addr}: {e}");
                return;
            }
        };
        info!("WebSocket server listening on {addr}");

        loop {
            let (stream, peer) = match listener.accept().await {
                Ok(conn) => conn,
                Err(e) => {
                    warn!("Failed to accept TCP connection: {e}");
                    continue;
                }
            };

            info!("New TCP connection from {peer}");

            let clients = Arc::clone(&self.clients);
            let client_count = Arc::clone(&self.client_count);
            let next_id = Arc::clone(&self.next_id);
            let message_tx = self.message_tx.clone();
            let pin_manager = self.pin_manager.clone();
            let require_auth = self.require_auth.load(Ordering::Relaxed);
            let connection_log = Arc::clone(&self.connection_log);
            let auth_throttle = Arc::clone(&self.auth_throttle);

            tokio::spawn(async move {
                let ws_stream = match tokio_tungstenite::accept_async(stream).await {
                    Ok(ws) => ws,
                    Err(e) => {
                        warn!("WebSocket handshake failed for {peer}: {e}");
                        connection_log.record(ConnectionEventKind::Failed, peer.to_string(), Some(e.to_string()));
                        return;
                    }
                };

                info!("WebSocket connection established with {peer}");
                connection_log.record(ConnectionEventKind::Connected, peer.to_string(), None);
                let (write, mut read) = ws_stream.split();

                let client_id = next_id.fetch_add(1, Ordering::Relaxed);

                {
                    let mut locked = clients.lock().await;
                    locked.insert(client_id, ClientConnection {
                        sink: write,
                        // Auto-authenticate when auth is not required
                        authenticated: !require_auth,
                        message_count: 0,
                        window_start: Instant::now(),
                    });
                    client_count.store(locked.len(), Ordering::Relaxed);
                }
                if !require_auth {
                    info!("Client {peer} assigned id={client_id} (auto-authenticated, auth disabled), count: {}", client_count.load(Ordering::Relaxed));
                } else {
                    info!("Client {peer} assigned id={client_id}, count: {}", client_count.load(Ordering::Relaxed));
                }

                while let Some(result) = read.next().await {
                    match result {
                        Ok(msg) => {
                            if msg.is_text() {
                                let text = msg.into_text().unwrap_or_default();

                                // App-level size cap. See `crate::protocol::limits` —
                                // mirrors WSLimits.maxMessageBytes from Shared/Constants.swift.
                                if text.len() > crate::protocol::limits::MAX_MESSAGE_BYTES {
                                    info!("Dropping oversized message ({} bytes) from {peer}", text.len());
                                    continue;
                                }

                                // Redact before logging — auth messages carry the PIN
                                // and would otherwise land in plaintext logs.
                                let preview = crate::services::secret_redactor::redact(
                                    &text[..text.len().min(200)],
                                );
                                info!("WS recv from {peer}: {preview}");

                                // Rate limit check (before auth, to prevent unauthenticated floods)
                                {
                                    let mut locked = clients.lock().await;
                                    if let Some(client) = locked.get_mut(&client_id) {
                                        if !client.allow_message() {
                                            info!("Rate limited message from {peer}");
                                            continue;
                                        }
                                    }
                                }

                                // Check auth state
                                let is_authenticated = {
                                    let locked = clients.lock().await;
                                    locked.get(&client_id).map(|c| c.authenticated).unwrap_or(false)
                                };

                                if is_authenticated {
                                    // If already authenticated and client sends auth, just confirm
                                    let msg_type = message_type(&text);
                                    if msg_type.as_deref() == Some("auth") {
                                        info!("Client {peer} already authenticated, confirming");
                                        let result_msg = AuthResultMessage::success();
                                        let json = encode_message(&result_msg).unwrap_or_default();
                                        let mut locked = clients.lock().await;
                                        if let Some(client) = locked.get_mut(&client_id) {
                                            let _ = client.sink.send(Message::Text(json.into())).await;
                                        }
                                        continue;
                                    }
                                    // Forward to app handler
                                    if message_tx.send(text).is_err() {
                                        warn!("Message channel closed, dropping client {peer}");
                                        break;
                                    }
                                } else {
                                    // Only accept auth messages
                                    let msg_type = message_type(&text);
                                    if msg_type.as_deref() == Some("auth") {
                                        // Reject hard-locked hosts before doing any PIN work.
                                        let peer_ip = peer.ip();
                                        if let AuthDecision::Locked { remaining } = auth_throttle.check(peer_ip) {
                                            let secs = remaining.as_secs();
                                            warn!("Client {peer} locked, {secs}s remaining");
                                            connection_log.record(
                                                ConnectionEventKind::AuthFailed,
                                                peer.to_string(),
                                                Some(format!("locked ({secs}s remaining)")),
                                            );
                                            let result_msg = AuthResultMessage::failure(
                                                format!("Too many attempts; try again in {secs}s"),
                                            );
                                            let json = encode_message(&result_msg).unwrap_or_default();
                                            let mut locked = clients.lock().await;
                                            if let Some(client) = locked.get_mut(&client_id) {
                                                let _ = client.sink.send(Message::Text(json.into())).await;
                                            }
                                            continue;
                                        }
                                        let auth_msg: Option<AuthMessage> = serde_json::from_str(&text).ok();
                                        if let Some(auth) = auth_msg {
                                            if pin_manager.verify(&auth.pin) {
                                                auth_throttle.record_success(peer_ip);
                                                info!("Client {peer} authenticated successfully");
                                                connection_log.record(ConnectionEventKind::AuthSucceeded, peer.to_string(), None);
                                                let result_msg = AuthResultMessage::success();
                                                let json = encode_message(&result_msg).unwrap_or_default();

                                                let mut locked = clients.lock().await;
                                                if let Some(client) = locked.get_mut(&client_id) {
                                                    client.authenticated = true;
                                                    let _ = client.sink.send(Message::Text(json.into())).await;
                                                }
                                            } else {
                                                auth_throttle.record_failure(peer_ip);
                                                let delay_ms = match auth_throttle.check(peer_ip) {
                                                    AuthDecision::Proceed { delay_ms } => delay_ms,
                                                    // record_failure may have just tripped the lockout — fall
                                                    // through to a tiny delay so the response still goes out.
                                                    AuthDecision::Locked { .. } => 0,
                                                };
                                                warn!("Client {peer} auth failed: incorrect PIN (delaying {delay_ms}ms)");
                                                connection_log.record(ConnectionEventKind::AuthFailed, peer.to_string(), Some("incorrect PIN".into()));
                                                if delay_ms > 0 {
                                                    tokio::time::sleep(Duration::from_millis(delay_ms)).await;
                                                }
                                                let result_msg = AuthResultMessage::failure("Incorrect PIN".into());
                                                let json = encode_message(&result_msg).unwrap_or_default();

                                                let mut locked = clients.lock().await;
                                                if let Some(client) = locked.get_mut(&client_id) {
                                                    let _ = client.sink.send(Message::Text(json.into())).await;
                                                }
                                            }
                                        } else {
                                            warn!("Client {peer} sent malformed auth message");
                                        }
                                    } else {
                                        info!("Dropping non-auth message from unauthenticated client {peer}");
                                    }
                                }
                            } else if msg.is_close() {
                                info!("Client {peer} sent close frame");
                                break;
                            } else {
                                info!("WS recv non-text from {peer}: {:?}", msg);
                            }
                        }
                        Err(e) => {
                            warn!("WebSocket read error from {peer}: {e}");
                            break;
                        }
                    }
                }

                // Remove client on disconnect
                info!("Client {peer} (id={client_id}) disconnected");
                connection_log.record(ConnectionEventKind::Disconnected, peer.to_string(), None);
                let mut locked = clients.lock().await;
                locked.remove(&client_id);
                client_count.store(locked.len(), Ordering::Relaxed);
            });
        }
    }

    /// Send a text message to all authenticated clients, removing any that have errored.
    /// Each send is bounded by a short timeout so a single slow/dead client
    /// can't stall the broadcast loop or balloon memory while TCP keepalive
    /// takes its time noticing — see the Mac's backpressure fix.
    pub async fn broadcast(&self, message: &str) {
        // 5 seconds is generous for LAN/Tailscale but short enough that a
        // backgrounded phone doesn't pile up TTS audio chunks behind it.
        const SEND_TIMEOUT: Duration = Duration::from_secs(5);

        let mut clients = self.clients.lock().await;
        let mut dead_ids = Vec::new();

        for (id, client) in clients.iter_mut() {
            if !client.authenticated {
                continue;
            }
            let send_fut = client.sink.send(Message::Text(message.into()));
            match timeout(SEND_TIMEOUT, send_fut).await {
                Ok(Ok(())) => {}
                Ok(Err(e)) => {
                    warn!("Dropping dead WebSocket client id={id}: {e}");
                    dead_ids.push(*id);
                }
                Err(_) => {
                    warn!(
                        "Dropping slow WebSocket client id={id}: send exceeded {:?}",
                        SEND_TIMEOUT
                    );
                    dead_ids.push(*id);
                }
            }
        }

        for id in &dead_ids {
            if let Some(mut client) = clients.remove(id) {
                // Force the socket closed so any queued bytes in the kernel
                // send buffer get released immediately instead of lingering.
                let _ = client.sink.close().await;
            }
        }

        self.client_count.store(clients.len(), Ordering::Relaxed);
    }

    pub fn client_count(&self) -> usize {
        self.client_count.load(Ordering::Relaxed)
    }

    /// Send a WebSocket Ping to every authenticated client. Tungstenite
    /// auto-replies with Pong on the receiver, so we just rely on send
    /// failing to detect a half-closed connection. Mirrors Mac's 10s
    /// heartbeat. Drop unresponsive clients via the same pattern as
    /// `broadcast`.
    pub async fn heartbeat_ping(&self) {
        const SEND_TIMEOUT: Duration = Duration::from_secs(5);

        let mut clients = self.clients.lock().await;
        let mut dead_ids = Vec::new();
        for (id, client) in clients.iter_mut() {
            if !client.authenticated {
                continue;
            }
            let send_fut = client.sink.send(Message::Ping(Vec::new().into()));
            match timeout(SEND_TIMEOUT, send_fut).await {
                Ok(Ok(())) => {}
                _ => {
                    warn!("Dropping unresponsive WebSocket client id={id} on heartbeat");
                    dead_ids.push(*id);
                }
            }
        }
        for id in &dead_ids {
            if let Some(mut client) = clients.remove(id) {
                let _ = client.sink.close().await;
            }
        }
        self.client_count.store(clients.len(), Ordering::Relaxed);
    }
}
