//! The running host: state, clients, platform lanes, logs and the rules that
//! connect them. `services::ws_server` owns the sockets and calls in here;
//! `services::router` handles the phone's messages.
//!
//! Locking rule: no `std::sync::Mutex` guard is ever held across an `.await`,
//! and no platform call runs outside the lanes. Both are what keep one slow
//! `SendInput` from freezing everybody's heartbeat (spec 10.4 hang guard).
//! File writes (logs, settings) go to writer threads for the same reason.
//!
//! Ordering rules:
//! - `poll_lock` (async) serializes polls end to end, and each listing
//!   carries a sequence number taken on the query lane, so an older desktop
//!   can never be applied over a newer one;
//! - `publish_lock` covers "read the snapshot, send it", so snapshots leave
//!   in the order they were read: an older `layout_update` never follows a
//!   newer one;
//! - a client is marked authenticated only after its `auth_result`,
//!   `device_identity` and first `layout_update` are queued, under
//!   `publish_lock`, so no broadcast can reach it first.
//!
//! Lock order: `publish_lock` -> `state` -> `last_layout` / `last_front` ->
//! `clients`. Nothing takes them the other way round.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, RwLock};
use std::time::Duration;

use serde::Serialize;
use tokio::sync::{mpsc, Notify};

use crate::app_state::AppState;
use crate::platform::traits::{Platform, PlatformError};
use crate::platform::Lanes;
use crate::protocol::messages::{encode, AuthResult, DeviceIdentity, FrontmostChanged, Heartbeat, HeartbeatAck};
use crate::services::auth_throttle::{Attempt, AuthThrottle, Sender};
use crate::services::clock::SharedClock;
use crate::services::dedupe::DedupeTable;
use crate::services::logs::Logs;
use crate::services::pin_store;
use crate::services::prefs_store::PrefsStore;
use crate::services::quip_log::Severity;
use crate::services::settings::{Settings, SettingsStore};
use crate::services::writer::Writer;

/// `WebSocketServer.heartbeatInterval`.
pub const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);
/// Spec 3.2: poll the desktop every second.
pub const POLL_INTERVAL: Duration = Duration::from_secs(1);
/// Spec 3.2: two missed acks in a row are logged (never a disconnect).
pub const MISSED_ACKS_TO_LOG: u32 = 2;
/// Messages queued for one phone before it is treated as dead and dropped.
pub const CLIENT_QUEUE: usize = 1024;
/// A socket must be authenticated this long after it was accepted, or it is
/// closed. Longer than the 10 s upgrade deadline (`PRE_HANDSHAKE_DEADLINE`,
/// the Mac's `PreHandshakeReapPolicy`) on purpose: a phone with no saved PIN
/// shows its PIN prompt on the open socket (`WebSocketClient.swift`,
/// `onAuthRequired`), and the user may take more than 10 s to type it. The
/// Mac has no auth deadline at all; `MAX_UNAUTHENTICATED` bounds what a PIN-less
/// peer can hold meanwhile.
pub const PRE_AUTH_DEADLINE: Duration = Duration::from_secs(120);
/// Sockets accepted but not yet authenticated, at most. More are closed at
/// accept, so a LAN peer cannot pin unbounded sockets and tasks.
pub const MAX_UNAUTHENTICATED: usize = 16;
/// Of those, at most this many from one exact address (`Sender::address`,
/// so a neighbour in the same IPv6 /64 is not crowded out). One LAN peer can
/// then hold a quarter of the slots for `PRE_AUTH_DEADLINE`, not all of
/// them, and the owner's phone still gets in. A phone opens one socket per
/// backend row; two rows (LAN + Tailscale) reach the host from two addresses.
pub const MAX_UNAUTHENTICATED_PER_SENDER: usize = 4;
/// Of the `MAX_UNAUTHENTICATED`, at most this many from one network
/// (`Sender::network`: the /64 for IPv6, the address for IPv4). A device
/// rotating through its /64 then holds half the slots, not all of them, and
/// makes at most this many concurrent PIN guesses (spec 3.1 threat math).
/// The same number bounds the network's wrong PINs still in their delay,
/// counted apart from sockets (`GuessToken`), so closing a socket early
/// frees its slot but not its guess; a wrong PIN finding none free queues
/// for one. Neither locks a network out, and neither is consulted for a
/// right PIN.
pub const MAX_UNAUTHENTICATED_PER_NETWORK: usize = 8;

/// Per-connection limits (`HostConfig::limits`). Tests shorten the deadline.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectionLimits {
    pub pre_auth_deadline: Duration,
    pub max_unauthenticated: usize,
    pub max_unauthenticated_per_sender: usize,
    pub max_unauthenticated_per_network: usize,
}

impl Default for ConnectionLimits {
    fn default() -> Self {
        Self {
            pre_auth_deadline: PRE_AUTH_DEADLINE,
            max_unauthenticated: MAX_UNAUTHENTICATED,
            max_unauthenticated_per_sender: MAX_UNAUTHENTICATED_PER_SENDER,
            max_unauthenticated_per_network: MAX_UNAUTHENTICATED_PER_NETWORK,
        }
    }
}

/// Why `try_pre_auth_slot` refused a socket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreAuthRefusal {
    /// `max_unauthenticated` sockets are already waiting, from anyone.
    Full,
    /// `max_unauthenticated_per_sender` are already waiting from this sender.
    SenderFull,
    /// `max_unauthenticated_per_network` are already waiting from this
    /// sender's network.
    NetworkFull,
}

#[derive(Debug, Default)]
struct PreAuthCounts {
    total: usize,
    by_sender: HashMap<String, usize>,
    by_network: HashMap<String, usize>,
}

fn release(counts: &mut HashMap<String, usize>, key: &str) {
    if let Some(n) = counts.get_mut(key) {
        *n -= 1;
        if *n == 0 {
            counts.remove(key);
        }
    }
}

pub type ClientId = u64;

/// Sleeps the auth-failure delay. Injectable so the 10-failure lockout test
/// does not wait 9 s.
pub trait Sleeper: Send + Sync {
    fn sleep(&self, d: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>>;
}

pub struct TokioSleeper;

impl Sleeper for TokioSleeper {
    fn sleep(&self, d: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>> {
        Box::pin(tokio::time::sleep(d))
    }
}

/// When the heartbeat and poll fire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ticks {
    /// Real timers (`HEARTBEAT_INTERVAL`, `POLL_INTERVAL`).
    Auto,
    /// Only when a test calls `heartbeat_tick` / `poll_tick`.
    Manual,
}

pub struct HostConfig {
    pub device_id: String,
    pub display_name: String,
    pub local_urls: Vec<String>,
    /// `--fake-platform`: accept loopback peers only.
    pub loopback_only: bool,
    pub ticks: Ticks,
    pub limits: ConnectionLimits,
}

struct Client {
    tx: mpsc::Sender<String>,
    authenticated: bool,
    remote: String,
    pending_heartbeat: Option<i64>,
    missed_acks: u32,
}

pub struct Host {
    pub config: HostConfig,
    pub clock: SharedClock,
    pub logs: Logs,
    pub lanes: Lanes,
    pub dedupe: DedupeTable,
    /// Blocking: only ever used through `spawn_blocking`.
    pub prefs: Arc<PrefsStore>,
    pub sleeper: Arc<dyn Sleeper>,
    throttle: AuthThrottle,
    pin: RwLock<String>,
    settings: Option<Mutex<(SettingsStore, Settings)>>,
    settings_writer: Writer,
    state: Mutex<AppState>,
    clients: Mutex<HashMap<ClientId, Client>>,
    next_client: AtomicU64,
    heartbeat_seq: AtomicI64,
    last_layout: Mutex<Option<String>>,
    last_front: Mutex<Option<Option<String>>>,
    poll_failing: Mutex<u64>,
    poll_lock: tokio::sync::Mutex<()>,
    listing_seq: Arc<AtomicU64>,
    publish_lock: Mutex<()>,
    pre_auth: Arc<Mutex<PreAuthCounts>>,
    guesses: GuessBudget,
}

#[derive(Debug, Default)]
struct GuessCounts {
    in_delay: HashMap<String, usize>,
    queued: HashMap<String, usize>,
}

/// One of the `max_unauthenticated` slots, held for one sender and its
/// network; freed when the last clone drops (socket closed or authenticated,
/// and no wrong PIN of the socket still queued for a guess token).
#[derive(Clone)]
pub struct PreAuthSlot {
    _held: Arc<SlotInner>,
}

struct SlotInner {
    counts: Arc<Mutex<PreAuthCounts>>,
    sender: Sender,
}

impl Drop for SlotInner {
    fn drop(&mut self) {
        let mut c = lock(&self.counts);
        c.total -= 1;
        release(&mut c.by_sender, &self.sender.address);
        release(&mut c.by_network, &self.sender.network);
    }
}

/// The wrong PINs each network may have in their delay
/// (`max_unauthenticated_per_network`), and the wrong PINs queued for one.
/// Per network only: a right PIN is never looked up here, so no sender's
/// guesses can make another sender's right PIN fail.
#[derive(Clone)]
struct GuessBudget {
    counts: Arc<Mutex<GuessCounts>>,
    freed: Arc<Notify>,
    per_network: usize,
}

impl GuessBudget {
    fn new(per_network: usize) -> Self {
        Self { counts: Arc::default(), freed: Arc::new(Notify::new()), per_network }
    }

    fn try_take(&self, network: &str) -> Option<GuessToken> {
        let mut c = lock(&self.counts);
        let n = c.in_delay.get(network).copied().unwrap_or(0);
        if n >= self.per_network {
            return None;
        }
        c.in_delay.insert(network.to_string(), n + 1);
        Some(GuessToken { budget: self.clone(), network: network.to_string() })
    }

    /// Waits until `network` has a free token. The wait is counted in
    /// `queued` (`Host::guesses_queued`) for as long as it lasts.
    async fn take(self, network: String) -> GuessToken {
        let _queued = Queued::enter(&self.counts, &network);
        loop {
            // Registered before the check, so a token freed in between
            // still wakes this waiter.
            let freed = self.freed.notified();
            tokio::pin!(freed);
            freed.as_mut().enable();
            if let Some(token) = self.try_take(&network) {
                return token;
            }
            freed.await;
        }
    }
}

/// One wrong PIN waiting for a token, counted until dropped.
struct Queued {
    counts: Arc<Mutex<GuessCounts>>,
    network: String,
}

impl Queued {
    fn enter(counts: &Arc<Mutex<GuessCounts>>, network: &str) -> Self {
        *lock(counts).queued.entry(network.to_string()).or_insert(0) += 1;
        Self { counts: counts.clone(), network: network.to_string() }
    }
}

impl Drop for Queued {
    fn drop(&mut self) {
        release(&mut lock(&self.counts).queued, &self.network);
    }
}

/// One wrong PIN still in its delay, for one network. Held by a task of its
/// own until the delay ends, whether or not the socket is still open: a
/// right PIN is answered at once and a wrong one only after the delay, so a
/// peer could otherwise read "no answer yet" as "wrong", close, and guess
/// again at once.
struct GuessToken {
    budget: GuessBudget,
    network: String,
}

impl Drop for GuessToken {
    fn drop(&mut self) {
        release(&mut lock(&self.budget.counts).in_delay, &self.network);
        self.budget.freed.notify_waiters();
    }
}

/// Everything `Host::new` needs.
pub struct HostParts {
    pub config: HostConfig,
    pub platform: Arc<dyn Platform>,
    pub clock: SharedClock,
    pub logs: Logs,
    pub pin: String,
    pub prefs: PrefsStore,
    /// `None` in `--fake-platform` mode: nothing is persisted.
    pub settings: Option<(SettingsStore, Settings)>,
    pub sleeper: Arc<dyn Sleeper>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

impl Host {
    pub fn new(parts: HostParts) -> std::io::Result<Arc<Host>> {
        let (overrides, show_all) = match &parts.settings {
            Some((_, s)) => {
                let mut o = HashMap::new();
                for k in &s.enabled_windows {
                    o.insert(k.clone(), true);
                }
                for k in &s.disabled_windows {
                    o.insert(k.clone(), false);
                }
                (o, s.show_all_apps)
            }
            None => (HashMap::new(), false),
        };
        let guesses = GuessBudget::new(parts.config.limits.max_unauthenticated_per_network);
        Ok(Arc::new(Host {
            lanes: Lanes::spawn(parts.platform)?,
            dedupe: DedupeTable::new(parts.clock.clone()),
            throttle: AuthThrottle::new(parts.clock.clone()),
            config: parts.config,
            clock: parts.clock,
            logs: parts.logs,
            prefs: Arc::new(parts.prefs),
            sleeper: parts.sleeper,
            pin: RwLock::new(parts.pin),
            settings: parts.settings.map(Mutex::new),
            settings_writer: Writer::spawn("quip-settings-writer"),
            state: Mutex::new(AppState::new(overrides, show_all)),
            clients: Mutex::new(HashMap::new()),
            next_client: AtomicU64::new(1),
            heartbeat_seq: AtomicI64::new(0),
            last_layout: Mutex::new(None),
            last_front: Mutex::new(None),
            poll_failing: Mutex::new(0),
            poll_lock: tokio::sync::Mutex::new(()),
            listing_seq: Arc::new(AtomicU64::new(0)),
            publish_lock: Mutex::new(()),
            pre_auth: Arc::new(Mutex::new(PreAuthCounts::default())),
            guesses,
        }))
    }

    pub fn state(&self) -> MutexGuard<'_, AppState> {
        lock(&self.state)
    }

    pub fn pin(&self) -> String {
        self.pin.read().map(|p| p.clone()).unwrap_or_default()
    }

    /// Tray "New PIN": connected phones stay connected (spec 6).
    pub fn set_pin(&self, pin: String) {
        if let Ok(mut p) = self.pin.write() {
            *p = pin.clone();
        }
        self.with_settings(|s| s.pin = pin);
    }

    /// Mutate and persist settings (no-op in fake mode). The change is made
    /// here; the file write happens on the settings writer thread, in order,
    /// and a failure is logged to websocket.log.
    pub fn with_settings(&self, f: impl FnOnce(&mut Settings)) {
        if let Some(m) = &self.settings {
            let (store, snapshot) = {
                let mut g = lock(m);
                let (store, settings) = &mut *g;
                f(settings);
                (store.clone(), settings.clone())
            };
            let logs = self.logs.clone();
            self.settings_writer.run(move || {
                if let Err(e) = store.save(&snapshot) {
                    logs.ws(Severity::Error, &format!("settings NOT saved to {}: {e}", store.path().display()));
                }
            });
        }
    }

    /// Wait for queued settings saves, then queued log lines (tests,
    /// shutdown).
    pub fn flush(&self) {
        self.settings_writer.flush();
        self.logs.flush();
    }

    // --- clients ---

    pub fn register_client(&self, remote: String) -> (ClientId, mpsc::Receiver<String>) {
        let id = self.next_client.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = mpsc::channel(CLIENT_QUEUE);
        lock(&self.clients)
            .insert(id, Client { tx, authenticated: false, remote, pending_heartbeat: None, missed_acks: 0 });
        (id, rx)
    }

    pub fn remove_client(&self, id: ClientId) {
        lock(&self.clients).remove(&id);
    }

    pub fn is_authenticated(&self, id: ClientId) -> bool {
        lock(&self.clients).get(&id).map(|c| c.authenticated).unwrap_or(false)
    }

    pub fn authenticated_count(&self) -> usize {
        lock(&self.clients).values().filter(|c| c.authenticated).count()
    }

    /// Every connected client's id, ascending.
    pub fn client_ids(&self) -> Vec<ClientId> {
        let mut ids: Vec<ClientId> = lock(&self.clients).keys().copied().collect();
        ids.sort_unstable();
        ids
    }

    /// Take a pre-auth slot for a just-accepted socket from `sender`, or say
    /// why it is refused: the global `max_unauthenticated`, this address's
    /// `max_unauthenticated_per_sender` or this network's
    /// `max_unauthenticated_per_network` is reached. All counts move under
    /// one lock.
    pub fn try_pre_auth_slot(&self, sender: &Sender) -> Result<PreAuthSlot, PreAuthRefusal> {
        let limits = self.config.limits;
        let mut c = lock(&self.pre_auth);
        if c.total >= limits.max_unauthenticated {
            return Err(PreAuthRefusal::Full);
        }
        let mine = c.by_sender.get(&sender.address).copied().unwrap_or(0);
        if mine >= limits.max_unauthenticated_per_sender {
            return Err(PreAuthRefusal::SenderFull);
        }
        let network = c.by_network.get(&sender.network).copied().unwrap_or(0);
        if network >= limits.max_unauthenticated_per_network {
            return Err(PreAuthRefusal::NetworkFull);
        }
        c.total += 1;
        c.by_sender.insert(sender.address.clone(), mine + 1);
        c.by_network.insert(sender.network.clone(), network + 1);
        Ok(PreAuthSlot { _held: Arc::new(SlotInner { counts: self.pre_auth.clone(), sender: sender.clone() }) })
    }

    pub fn unauthenticated_count(&self) -> usize {
        lock(&self.pre_auth).total
    }

    /// Sockets from `sender` waiting for auth.
    pub fn unauthenticated_from(&self, sender: &str) -> usize {
        lock(&self.pre_auth).by_sender.get(sender).copied().unwrap_or(0)
    }

    /// Sockets from `network` (`Sender::network`) waiting for auth.
    pub fn unauthenticated_from_network(&self, network: &str) -> usize {
        lock(&self.pre_auth).by_network.get(network).copied().unwrap_or(0)
    }

    /// Wrong PINs from `network` still in their delay.
    pub fn guesses_in_delay(&self, network: &str) -> usize {
        lock(&self.guesses.counts).in_delay.get(network).copied().unwrap_or(0)
    }

    /// Wrong PINs from `network` waiting for a free guess token.
    pub fn guesses_queued(&self, network: &str) -> usize {
        lock(&self.guesses.counts).queued.get(network).copied().unwrap_or(0)
    }

    /// Queue raw JSON for one client. A full queue means the phone stopped
    /// reading; it is dropped (its writer then closes the socket) rather than
    /// letting memory grow, the Mac's `maxPendingBytes` idea.
    pub fn send_raw(&self, id: ClientId, json: String) {
        let mut clients = lock(&self.clients);
        let full = match clients.get(&id) {
            Some(c) => c.tx.try_send(json).is_err(),
            None => false,
        };
        if full {
            if let Some(c) = clients.remove(&id) {
                drop(clients);
                self.logs.ws(Severity::Warn, &format!("dropping {}: send queue full or closed", c.remote));
            }
        }
    }

    pub fn send<T: Serialize>(&self, id: ClientId, msg: &T) {
        if let Some(json) = encode(msg) {
            self.send_raw(id, json);
        }
    }

    /// To every authenticated client (acks and errors go to all phones, as
    /// the Mac broadcasts them).
    pub fn broadcast<T: Serialize>(&self, msg: &T) {
        let Some(json) = encode(msg) else { return };
        let ids: Vec<ClientId> =
            lock(&self.clients).iter().filter(|(_, c)| c.authenticated).map(|(id, _)| *id).collect();
        for id in ids {
            self.send_raw(id, json.clone());
        }
    }

    // --- auth (spec 3.1) ---

    /// The first thing a new socket hears: the phone waits for this before it
    /// sends its PIN (`WebSocketClient.swift`, `auth_required`).
    pub fn greet(&self, id: ClientId) {
        self.send(id, &AuthResult::auth_required());
    }

    /// Handle an `auth` frame (decoded or not) from `sender`, the peer's
    /// throttle keys (`AuthThrottle::attempt`). `slot` is the socket's
    /// pre-auth slot (`None` once authenticated): a wrong PIN that has to
    /// queue for a guess token keeps it until it gets one, even if the
    /// socket closes meanwhile.
    pub async fn handle_auth(&self, id: ClientId, sender: &Sender, pin: Option<String>, slot: Option<PreAuthSlot>) {
        let host = &sender.address;
        let Some(pin) = pin else {
            self.send(id, &AuthResult::failure("Malformed auth message"));
            return;
        };
        let expected = self.pin();
        if expected.is_empty() {
            self.send(id, &AuthResult::failure("Server PIN not configured"));
            return;
        }
        // Check, compare and record under one throttle lock (`attempt`).
        match self.throttle.attempt(sender, pin_store::matches(&expected, &pin)) {
            Attempt::Locked { remaining } => {
                let secs = remaining.as_secs_f64().ceil() as u64;
                self.logs.ws(Severity::Warn, &format!("auth: {host} locked, {secs}s remaining"));
                self.send(id, &AuthResult::failure(format!("Too many attempts; try again in {secs}s")));
            }
            Attempt::Accepted => {
                self.logs.ws(Severity::Info, &format!("auth ok from {host}"));
                // Under publish_lock: the handshake is queued in order, and
                // the client joins the broadcast set only after it, so no
                // layout_update, error or ack can reach it before auth_result.
                let _g = lock(&self.publish_lock);
                self.send(id, &AuthResult::success());
                self.send(
                    id,
                    &DeviceIdentity::windows(
                        self.config.device_id.clone(),
                        self.config.display_name.clone(),
                        self.config.local_urls.clone(),
                    ),
                );
                // From memory, not the platform: a client authenticating while
                // the input lane is busy still gets its grid at once.
                let (snapshot, front) = {
                    let s = self.state();
                    (s.snapshot(), s.frontmost_id())
                };
                self.send(id, &snapshot);
                if front.is_some() {
                    self.send(id, &FrontmostChanged::new(front));
                }
                if let Some(c) = lock(&self.clients).get_mut(&id) {
                    c.authenticated = true;
                }
            }
            Attempt::Rejected { delay_ms } => {
                // Never log either PIN; lengths only (WebSocketServer.swift).
                self.logs.ws(
                    Severity::Warn,
                    &format!(
                        "auth failed from {host}: incorrect PIN (got {}, expected {}), answering in {delay_ms}ms",
                        pin_store::describe_for_log(&pin),
                        pin_store::describe_for_log(&expected)
                    ),
                );
                // A wrong PIN holds one of its network's guess tokens for
                // its delay. With none free it queues for one, keeping the
                // socket's pre-auth slot, so the network's checks stay at
                // `max_unauthenticated_per_network` per delay plus what its
                // slots can queue (spec 3.1). Token, queue and delay live in
                // their own task, so a socket closed meanwhile (`ws_server`
                // drops this future) still counts them.
                let budget = self.guesses.clone();
                let network = sender.network.clone();
                let ready = budget.try_take(&network);
                let queued = if ready.is_none() {
                    self.logs.ws(
                        Severity::Warn,
                        &format!(
                            "auth: {host} wrong PIN queued: network {network} has {} wrong PINs in their delay",
                            budget.per_network
                        ),
                    );
                    slot
                } else {
                    None
                };
                let sleeper = self.sleeper.clone();
                let waited = tokio::spawn(async move {
                    let guess = match ready {
                        Some(token) => token,
                        None => budget.take(network).await,
                    };
                    drop(queued);
                    sleeper.sleep(Duration::from_millis(delay_ms)).await;
                    drop(guess);
                });
                let _ = waited.await;
                self.send(id, &AuthResult::failure("Incorrect PIN"));
            }
        }
    }

    // --- heartbeat (spec 3.2) ---

    pub fn heartbeat_tick(&self) {
        let ts = self.clock.unix_seconds();
        let mut warnings = vec![];
        let mut sends = vec![];
        {
            let mut clients = lock(&self.clients);
            for (id, c) in clients.iter_mut().filter(|(_, c)| c.authenticated) {
                if c.pending_heartbeat.is_some() {
                    c.missed_acks += 1;
                    if c.missed_acks == MISSED_ACKS_TO_LOG {
                        warnings.push(format!("heartbeat: {} missed {MISSED_ACKS_TO_LOG} acks in a row", c.remote));
                    }
                }
                let seq = self.heartbeat_seq.fetch_add(1, Ordering::SeqCst) + 1;
                c.pending_heartbeat = Some(seq);
                sends.push((*id, seq));
            }
        }
        for w in warnings {
            self.logs.ws(Severity::Warn, &w);
        }
        for (id, seq) in sends {
            self.send(id, &Heartbeat::new(seq, ts));
        }
    }

    pub fn heartbeat_ack(&self, id: ClientId, ack: &HeartbeatAck) {
        if let Some(c) = lock(&self.clients).get_mut(&id) {
            // Any ack proves the phone is reading, even a late one.
            if c.pending_heartbeat == Some(ack.seq) {
                c.pending_heartbeat = None;
            }
            c.missed_acks = 0;
        }
    }

    pub fn missed_acks(&self, id: ClientId) -> Option<u32> {
        lock(&self.clients).get(&id).map(|c| c.missed_acks)
    }

    // --- desktop poll (spec 3.2) ---

    /// List the desktop on the query lane, update state, publish changes.
    /// Polls run one at a time (`poll_lock`), and a listing older than the
    /// one already applied is dropped (`AppState::update_if_newer`).
    pub async fn poll_tick(&self) {
        let _serial = self.poll_lock.lock().await;
        let seq_source = self.listing_seq.clone();
        let listed = self
            .lanes
            .query(move |p| {
                let seq = seq_source.fetch_add(1, Ordering::SeqCst);
                let w = p.list_windows()?;
                let d = p.list_displays()?;
                let f = p.foreground_window()?;
                Ok::<_, PlatformError>((seq, w, d, f))
            })
            .await;
        match listed {
            Ok(Ok((seq, w, d, f))) => {
                {
                    let mut failing = lock(&self.poll_failing);
                    if *failing > 0 {
                        self.logs.ws(Severity::Info, &format!("window listing recovered after {} failures", *failing));
                        *failing = 0;
                    }
                }
                let applied = self.state().update_if_newer(seq, w, d, f);
                if applied {
                    self.publish();
                }
            }
            Ok(Err(e)) => self.poll_failed(&e.to_string()),
            Err(_) => self.poll_failed("platform thread gone"),
        }
    }

    /// Throttled like `SESSION_FETCH failed streak=N` on the Mac: the 1st and
    /// every 30th. The last good state is kept.
    fn poll_failed(&self, why: &str) {
        let mut failing = lock(&self.poll_failing);
        *failing += 1;
        if *failing == 1 || (*failing).is_multiple_of(30) {
            self.logs.ws(
                Severity::Warn,
                &format!("window listing failed streak={} action=kept-last-good-state: {why}", *failing),
            );
        }
    }

    /// Broadcast the snapshot if it changed (an identical one is sent once),
    /// and `frontmost_changed` if the foreground changed.
    pub fn publish(&self) {
        let _g = lock(&self.publish_lock);
        let (snapshot, front) = {
            let s = self.state();
            (s.snapshot(), s.frontmost_id())
        };
        if let Some(json) = encode(&snapshot) {
            let changed = {
                let mut last = lock(&self.last_layout);
                if last.as_deref() == Some(json.as_str()) {
                    false
                } else {
                    *last = Some(json.clone());
                    true
                }
            };
            if changed {
                let ids: Vec<ClientId> =
                    lock(&self.clients).iter().filter(|(_, c)| c.authenticated).map(|(id, _)| *id).collect();
                for id in ids {
                    self.send_raw(id, json.clone());
                }
            }
        }
        let front_changed = {
            let mut last = lock(&self.last_front);
            if last.as_ref() == Some(&front) {
                false
            } else {
                let first = last.is_none();
                *last = Some(front.clone());
                // The first observation is a baseline, not a change; phones
                // that connect get the current value at auth.
                !first
            }
        };
        if front_changed {
            self.broadcast(&FrontmostChanged::new(front));
        }
    }

    /// Flip `show_all_apps` (tray toggle) and republish.
    pub fn set_show_all_apps(&self, on: bool) {
        self.state().set_show_all_apps(on);
        self.with_settings(|s| s.show_all_apps = on);
        self.publish();
    }
}
