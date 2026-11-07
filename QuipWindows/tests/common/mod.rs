//! Shared harness: a real `ws_server` on a random loopback port, the fake
//! platform, a manual clock, manual ticks, and a real tokio-tungstenite
//! client standing in for the phone.
#![allow(dead_code)]

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use quip_windows::host::{ConnectionLimits, Host, HostConfig, HostParts, Sleeper, Ticks, TokioSleeper};
use quip_windows::platform::fake::{FakePlatform, Fixture};
use quip_windows::services::clock::ManualClock;
use quip_windows::services::log_paths::LogPaths;
use quip_windows::services::logs::Logs;
use quip_windows::services::prefs_store::PrefsStore;
use quip_windows::services::settings::{Settings, SettingsStore};
use quip_windows::services::ws_server;
use serde_json::Value;
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

pub const PIN: &str = "24681357";
pub const DEVICE_ID: &str = "6BA7B810-9DAD-41D1-80B4-00C04FD430C8";

pub const FIXTURE: &str = r#"{
  "displays":[
    {"deviceName":"\\\\.\\DISPLAY1","name":"FakeWindows Display","bounds":{"x":0,"y":0,"width":1920,"height":1080},
     "workArea":{"x":0,"y":0,"width":1920,"height":1040},"isPrimary":true}],
  "foreground": 101,
  "windows":[
    {"handle":101,"pid":1,"title":"pwsh one","className":"CASCADIA_HOSTING_WINDOW_CLASS",
     "exePath":"C:\\WT\\WindowsTerminal.exe","shells":["pwsh.exe"],"visible":{"x":0,"y":0,"width":960,"height":1040}},
    {"handle":102,"pid":2,"title":"cmd two","className":"ConsoleWindowClass",
     "exePath":"C:\\Windows\\System32\\conhost.exe","shells":["cmd.exe"],"visible":{"x":960,"y":0,"width":960,"height":1040}},
    {"handle":103,"pid":3,"title":"notes","className":"Notepad","exePath":"C:\\Windows\\notepad.exe",
     "productName":"Notepad","visible":{"x":100,"y":100,"width":500,"height":400}}
  ]}"#;

/// Records requested auth delays and returns at once.
#[derive(Default)]
pub struct RecordingSleeper {
    pub delays: Mutex<Vec<Duration>>,
}

impl Sleeper for RecordingSleeper {
    fn sleep(&self, d: Duration) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        if let Ok(mut v) = self.delays.lock() {
            v.push(d);
        }
        Box::pin(async {})
    }
}

/// Never finishes: a wrong PIN's reply waits until the socket goes away.
pub struct HangingSleeper;

impl Sleeper for HangingSleeper {
    fn sleep(&self, _: Duration) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        Box::pin(std::future::pending())
    }
}

/// Each sleep ends when the test hands out a permit (`release`): a wrong
/// PIN's delay ends exactly when the test says so.
pub struct GateSleeper(Arc<tokio::sync::Semaphore>);

impl GateSleeper {
    pub fn new() -> Self {
        GateSleeper(Arc::new(tokio::sync::Semaphore::new(0)))
    }

    /// End `n` delays, oldest waiter first.
    pub fn release(&self, n: usize) {
        self.0.add_permits(n);
    }
}

impl Sleeper for GateSleeper {
    fn sleep(&self, _: Duration) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        let gate = self.0.clone();
        Box::pin(async move {
            if let Ok(permit) = gate.acquire_owned().await {
                permit.forget();
            }
        })
    }
}

pub struct Harness {
    pub host: Arc<Host>,
    pub fake: FakePlatform,
    pub addr: SocketAddr,
    pub clock: Arc<ManualClock>,
    pub sleeper: Arc<RecordingSleeper>,
    pub dir: tempfile::TempDir,
}

pub struct Opts {
    pub real_sleeper: bool,
    pub prefs_file: bool,
    pub limits: ConnectionLimits,
    /// Overrides `real_sleeper` when set.
    pub sleeper: Option<Arc<dyn Sleeper>>,
}

impl Default for Opts {
    fn default() -> Self {
        Opts { real_sleeper: false, prefs_file: true, limits: ConnectionLimits::default(), sleeper: None }
    }
}

pub async fn start() -> Harness {
    start_with(Opts::default()).await
}

pub async fn start_with(opts: Opts) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let fake = FakePlatform::from_fixture(&Fixture::parse(FIXTURE).unwrap());
    let clock = ManualClock::new(1_800_000_000);
    let sleeper = Arc::new(RecordingSleeper::default());
    let store = SettingsStore::in_dir(&dir.path().join("config"));
    let mut settings = Settings::fresh(&mut rand::rng());
    settings.pin = PIN.into();
    settings.device_id = DEVICE_ID.into();
    store.save(&settings).unwrap();
    let host = Host::new(HostParts {
        config: HostConfig {
            device_id: DEVICE_ID.into(),
            display_name: "Test PC".into(),
            local_urls: vec!["ws://192.0.2.10:8765".into()],
            loopback_only: true,
            ticks: Ticks::Manual,
            limits: opts.limits,
        },
        platform: Arc::new(fake.clone()),
        clock: clock.clone(),
        logs: Logs::new(LogPaths::new(dir.path().join("Logs")), clock.clone(), false),
        pin: PIN.into(),
        prefs: if opts.prefs_file {
            PrefsStore::file(dir.path().join("config").join("phone-prefs.json"))
        } else {
            PrefsStore::NoBackup
        },
        settings: Some((store, settings)),
        sleeper: match opts.sleeper {
            Some(s) => s,
            None if opts.real_sleeper => Arc::new(TokioSleeper),
            None => sleeper.clone(),
        },
    })
    .unwrap();
    host.poll_tick().await;
    let listener = ws_server::bind("127.0.0.1:0".parse().unwrap()).await.unwrap();
    let addr = listener.local_addr().unwrap();
    ws_server::spawn(host.clone(), listener);
    Harness { host, fake, addr, clock, sleeper, dir }
}

impl Harness {
    /// A log file's content, after every queued line is written.
    pub fn log(&self, name: &str) -> String {
        self.host.flush();
        std::fs::read_to_string(self.dir.path().join("Logs").join(name)).unwrap_or_default()
    }

    /// `settings.toml`, after every queued save.
    pub fn settings(&self) -> String {
        self.host.flush();
        std::fs::read_to_string(self.dir.path().join("config").join("settings.toml")).unwrap_or_default()
    }

    pub fn window_id(&self, handle: u64) -> String {
        self.host.state().windows().iter().find(|w| w.platform.handle == handle).unwrap().id.clone()
    }
}

pub struct Phone {
    pub ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
}

pub async fn connect(addr: SocketAddr) -> Phone {
    let (ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}")).await.unwrap();
    Phone { ws }
}

impl Phone {
    pub async fn send(&mut self, v: Value) {
        self.ws.send(Message::Text(v.to_string())).await.unwrap();
    }

    pub async fn send_raw(&mut self, s: &str) {
        self.ws.send(Message::Text(s.to_string())).await.unwrap();
    }

    /// Next JSON message, or `None` within `wait`.
    pub async fn recv_within(&mut self, wait: Duration) -> Option<Value> {
        loop {
            match tokio::time::timeout(wait, self.ws.next()).await {
                Ok(Some(Ok(Message::Text(t)))) => return Some(serde_json::from_str(&t).unwrap()),
                Ok(Some(Ok(Message::Ping(_) | Message::Pong(_)))) => continue,
                Ok(Some(Ok(Message::Close(_)))) => return None,
                Ok(Some(Ok(other))) => panic!("unexpected frame {other:?}"),
                Ok(Some(Err(e))) => panic!("socket error {e}"),
                Ok(None) => return None,
                Err(_) => return None,
            }
        }
    }

    pub async fn recv(&mut self) -> Value {
        self.recv_within(Duration::from_secs(5)).await.expect("expected a message")
    }

    /// Skip until a message of `type_` arrives.
    pub async fn recv_type(&mut self, type_: &str) -> Value {
        loop {
            let m = self.recv().await;
            if m["type"] == type_ {
                return m;
            }
        }
    }

    pub async fn assert_silent(&mut self, wait: Duration) {
        if let Some(m) = self.recv_within(wait).await {
            panic!("expected silence, got {m}");
        }
    }

    /// Connect-time `auth_required`, then the PIN, then the three handshake
    /// messages. Returns the first `layout_update`.
    pub async fn pair(&mut self) -> Value {
        let first = self.recv().await;
        assert_eq!(first["error"], "auth_required");
        self.send(serde_json::json!({"type":"auth","pin":PIN})).await;
        assert_eq!(self.recv().await["success"], true);
        assert_eq!(self.recv().await["type"], "device_identity");
        let layout = self.recv().await;
        assert_eq!(layout["type"], "layout_update");
        layout
    }
}

/// A phone that is paired, with the post-auth `frontmost_changed` drained.
pub async fn paired(addr: SocketAddr) -> (Phone, Value) {
    let mut p = connect(addr).await;
    let layout = p.pair().await;
    // The fixture's foreground (101) is a tracked terminal.
    assert_eq!(p.recv().await["type"], "frontmost_changed");
    (p, layout)
}
