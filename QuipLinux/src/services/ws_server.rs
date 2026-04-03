use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use futures_util::sink::SinkExt;
use futures_util::stream::{SplitSink, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;
use tracing::{error, info, warn};

type WsSink = SplitSink<WebSocketStream<TcpStream>, Message>;

pub struct WsServer {
    port: u16,
    clients: Arc<Mutex<Vec<WsSink>>>,
    client_count: Arc<AtomicUsize>,
    message_tx: mpsc::UnboundedSender<String>,
}

impl WsServer {
    pub fn new(port: u16, message_tx: mpsc::UnboundedSender<String>) -> Self {
        Self {
            port,
            clients: Arc::new(Mutex::new(Vec::new())),
            client_count: Arc::new(AtomicUsize::new(0)),
            message_tx,
        }
    }

    pub async fn run(&self) {
        let addr = format!("127.0.0.1:{}", self.port);
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
            let message_tx = self.message_tx.clone();

            tokio::spawn(async move {
                let ws_stream = match tokio_tungstenite::accept_async(stream).await {
                    Ok(ws) => ws,
                    Err(e) => {
                        warn!("WebSocket handshake failed for {peer}: {e}");
                        return;
                    }
                };

                info!("WebSocket connection established with {peer}");
                let (write, mut read) = ws_stream.split();

                {
                    let mut locked = clients.lock().await;
                    locked.push(write);
                    client_count.store(locked.len(), Ordering::Relaxed);
                }
                info!("Client count: {}", client_count.load(Ordering::Relaxed));

                while let Some(result) = read.next().await {
                    match result {
                        Ok(msg) => {
                            if msg.is_text() {
                                let text = msg.into_text().unwrap_or_default();
                                if message_tx.send(text).is_err() {
                                    warn!("Message channel closed, dropping client {peer}");
                                    break;
                                }
                            } else if msg.is_close() {
                                info!("Client {peer} sent close frame");
                                break;
                            }
                        }
                        Err(e) => {
                            warn!("WebSocket read error from {peer}: {e}");
                            break;
                        }
                    }
                }

                // Client disconnected — we cannot easily identify which sink belongs
                // to this peer without extra bookkeeping, so broadcast() will prune
                // dead sinks on next send. Just update the count optimistically.
                info!("Client {peer} disconnected");
                // Count will be corrected on next broadcast when dead sinks are removed.
            });
        }
    }

    /// Send a text message to all connected clients, removing any that have errored.
    pub async fn broadcast(&self, message: &str) {
        let mut clients = self.clients.lock().await;
        let mut alive = Vec::with_capacity(clients.len());

        for mut sink in clients.drain(..) {
            match sink.send(Message::Text(message.into())).await {
                Ok(()) => alive.push(sink),
                Err(e) => {
                    warn!("Dropping dead WebSocket client: {e}");
                }
            }
        }

        self.client_count.store(alive.len(), Ordering::Relaxed);
        *clients = alive;
    }

    pub fn client_count(&self) -> usize {
        self.client_count.load(Ordering::Relaxed)
    }
}
