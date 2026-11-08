//! `Quip.exe` with no arguments: the real host behind the tray (spec 6).
//!
//! `start` is the wiring, the same as `fake_mode::start` but with real
//! settings, real logs and any platform, so it is tested on the Mac with the
//! fake one: settings from `%APPDATA%\Quip\settings.toml` (created on first
//! run; an unreadable file stops Quip, never a new PIN), logs in
//! `%LOCALAPPDATA%\Quip\Logs`, phone prefs in `%APPDATA%\Quip`, the server
//! on `0.0.0.0:<port>` with the 1 s poll and heartbeat.
//!
//! `run` (Windows) is the process: one instance, then `start` on the
//! Win32 platform, Bonjour (`advertise_when_ready`, which waits for a LAN
//! address; `MdnsHolder` stops it on Quit), then the tray
//! loop on the main thread. Every error before
//! the tray is up is shown in a message box (there is no console).

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::host::{ConnectionLimits, Host, HostConfig, HostParts, Sleeper, Ticks, TokioSleeper};
use crate::platform::traits::Platform;
use crate::services::clock::SystemClock;
use crate::services::local_addresses::{interface_ipv4s, websocket_urls};
use crate::services::log_paths::{default_config_dir, LogPaths};
use crate::services::logs::Logs;
use crate::services::mdns_advertiser::Advert;
use crate::services::prefs_store::PrefsStore;
use crate::services::quip_log::Severity;
use crate::services::settings::{LoadOutcome, SettingsError, SettingsStore};
use crate::services::ws_server::{self, BindError};

pub const PREFS_FILE: &str = "phone-prefs.json";

/// Where settings and logs live.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppPaths {
    pub config_dir: PathBuf,
    pub log_dir: PathBuf,
}

impl AppPaths {
    /// `%APPDATA%\Quip` and `%LOCALAPPDATA%\Quip\Logs` on Windows (see
    /// `log_paths`).
    pub fn from_env(env: &dyn Fn(&str) -> Option<String>) -> Self {
        Self { config_dir: default_config_dir(env), log_dir: LogPaths::default_dir(env) }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StartOptions {
    pub bind_ip: IpAddr,
    /// Listen here instead of the settings' port (tests).
    pub port: Option<u16>,
}

impl Default for StartOptions {
    fn default() -> Self {
        Self { bind_ip: IpAddr::V4(Ipv4Addr::UNSPECIFIED), port: None }
    }
}

#[derive(Debug)]
pub enum StartError {
    Settings(SettingsError),
    Bind(BindError),
    Threads(String),
}

impl std::fmt::Display for StartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StartError::Settings(e) => {
                write!(f, "{e}\n\nQuip did not start, so your PIN and pairing are unchanged. Close whatever holds the file (a backup or antivirus scan) and start Quip again.")
            }
            StartError::Bind(e) => write!(f, "{e}"),
            StartError::Threads(e) => write!(f, "cannot start Quip's worker threads: {e}"),
        }
    }
}

/// The running host.
pub struct Running {
    pub host: Arc<Host>,
    pub addr: SocketAddr,
    pub settings_path: PathBuf,
}

/// Loads settings, starts the host on `platform` and serves. Call inside a
/// tokio runtime; blocking file and adapter reads go through
/// `spawn_blocking`.
pub async fn start(paths: &AppPaths, platform: Arc<dyn Platform>, opts: StartOptions) -> Result<Running, StartError> {
    let store = SettingsStore::in_dir(&paths.config_dir);
    let s2 = store.clone();
    let (settings, outcome) = tokio::task::spawn_blocking(move || s2.load_or_create(&mut rand::rng()))
        .await
        .map_err(|e| StartError::Threads(e.to_string()))?
        .map_err(StartError::Settings)?;
    let clock = SystemClock::shared();
    let logs = Logs::new(LogPaths::new(paths.log_dir.clone()), clock.clone(), false);
    let port = opts.port.unwrap_or(settings.port);
    logs.ws(Severity::Info, &format!("start: {}, port {port}", crate::build_info::product_line()));
    match &outcome {
        LoadOutcome::Created => {
            logs.ws(Severity::Info, &format!("settings: created {} (new PIN and device id)", store.path().display()))
        }
        LoadOutcome::Loaded => {}
        LoadOutcome::Recovered { bad_path, reason } => logs.ws(
            Severity::Error,
            &format!(
                "settings: {} was unusable ({reason}); moved to {} and made a new one (new PIN and device id)",
                store.path().display(),
                bad_path.display()
            ),
        ),
    }
    let ips = tokio::task::spawn_blocking(interface_ipv4s).await.unwrap_or_default();
    let display_name = hostname::get().ok().and_then(|h| h.into_string().ok()).unwrap_or_else(|| "Windows PC".into());
    let host = Host::new(HostParts {
        config: HostConfig {
            device_id: settings.device_id.clone(),
            display_name,
            local_urls: websocket_urls(&ips, port),
            loopback_only: false,
            ticks: Ticks::Auto,
            limits: ConnectionLimits::default(),
        },
        platform,
        clock,
        logs,
        pin: settings.pin.clone(),
        prefs: PrefsStore::file(paths.config_dir.join(PREFS_FILE)),
        settings: Some((store.clone(), settings)),
        sleeper: Arc::new(TokioSleeper),
    })
    .map_err(|e| StartError::Threads(e.to_string()))?;
    host.poll_tick().await;
    let listener = ws_server::bind(SocketAddr::new(opts.bind_ip, port)).await.map_err(|e| {
        host.logs.ws(Severity::Error, &format!("{e}"));
        StartError::Bind(e)
    })?;
    let addr = listener.local_addr().map_err(|e| StartError::Bind(BindError::Other(e.to_string())))?;
    ws_server::spawn(host.clone(), listener);
    Ok(Running { host, addr, settings_path: store.path().to_path_buf() })
}

/// How often a host with no LAN address looks again (spec 6).
pub const MDNS_RETRY: Duration = Duration::from_secs(30);
/// While waiting, a log line on the 1st try and every this many after.
pub const MDNS_LOG_EVERY: u32 = 10;

fn logged_try(n: u32) -> bool {
    n == 1 || n.is_multiple_of(MDNS_LOG_EVERY)
}

/// Advertises the running host over Bonjour (spec 3.1, 6) as soon as it
/// can: tries at once, then every `MDNS_RETRY` until `read_addrs` gives a
/// LAN address and `start` succeeds, and returns what `start` made. Every
/// outcome is logged to websocket.log (waiting and failures on the 1st try
/// and every 10th); the host serves meanwhile (the phone connects by its
/// saved or scanned URL). Cancel it by dropping or aborting the future. Only
/// the real app calls this: `--fake-platform` never advertises. `start` is
/// async so the real one can run off the tokio workers
/// (`Keeper::start_blocking`).
pub async fn advertise_when_ready<T, R, F, S, G>(
    host: &Host,
    port: u16,
    mut read_addrs: R,
    sleeper: &dyn Sleeper,
    mut start: S,
) -> T
where
    R: FnMut() -> F,
    F: std::future::Future<Output = Vec<Ipv4Addr>>,
    S: FnMut(&Advert) -> G,
    G: std::future::Future<Output = Result<T, String>>,
{
    let did_prefix: String = host.config.device_id.chars().take(8).collect();
    let mut tries = 0u32;
    let mut failures = 0u32;
    loop {
        tries += 1;
        let addresses = read_addrs().await;
        match Advert::new(&host.config.display_name, &addresses, port, &host.config.device_id) {
            None if logged_try(tries) => host.logs.ws(
                Severity::Warn,
                &format!(
                    "mDNS: no LAN address, not advertising yet (pair with the QR or the URL); checking every {} s (try {tries})",
                    MDNS_RETRY.as_secs()
                ),
            ),
            None => {}
            Some(advert) => match start(&advert).await {
                Ok(a) => {
                    let found = if tries > 1 { "LAN address found, " } else { "" };
                    host.logs.ws(
                        Severity::Info,
                        &format!(
                            "mDNS: {found}advertising _quip._tcp on {} LAN address(es), port {port} (did={did_prefix})",
                            advert.ips.len()
                        ),
                    );
                    return a;
                }
                Err(e) => {
                    failures += 1;
                    if logged_try(failures) {
                        host.logs.ws(
                            Severity::Error,
                            &format!("mDNS: not advertising: {e}; retrying every {} s (try {tries})", MDNS_RETRY.as_secs()),
                        );
                    }
                }
            },
        }
        sleeper.sleep(MDNS_RETRY).await;
    }
}

/// Where the advertiser is.
enum Slot<T> {
    Waiting,
    Up(T),
    /// `stop` ran: anything started from now on is dropped at once.
    Stopped,
}

fn slot<T>(m: &Mutex<Slot<T>>) -> std::sync::MutexGuard<'_, Slot<T>> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

/// The Bonjour advertiser, or the task still waiting to make one. `stop`
/// (the tray's Quit) ends both.
pub struct MdnsHolder<T: Send + 'static> {
    task: tokio::task::JoinHandle<()>,
    slot: Arc<Mutex<Slot<T>>>,
}

/// What the waiting task hands a started advertiser to.
pub struct Keeper<T> {
    slot: Arc<Mutex<Slot<T>>>,
    on_late_stop: Arc<dyn Fn() + Send + Sync>,
}

impl<T> Clone for Keeper<T> {
    fn clone(&self) -> Self {
        Keeper { slot: self.slot.clone(), on_late_stop: self.on_late_stop.clone() }
    }
}

impl<T: Send + 'static> Keeper<T> {
    /// Runs `start` (synchronous: it binds a socket and registers the
    /// service) on a blocking thread, so it never holds a tokio worker, and
    /// keeps what it made. `abort` cannot cut it short; when `stop` ran
    /// first, what it made is dropped at once instead (its goodbye goes out)
    /// and `on_late_stop` runs (the "mDNS: stopped" line).
    pub async fn start_blocking<F>(&self, start: F) -> Result<(), String>
    where
        F: FnOnce() -> Result<T, String> + Send + 'static,
    {
        let k = self.clone();
        match tokio::task::spawn_blocking(move || start().map(|a| k.keep(a))).await {
            Ok(r) => r,
            Err(e) => Err(format!("the start did not finish: {e}")),
        }
    }

    fn keep(&self, made: T) {
        let mut s = slot(&self.slot);
        if matches!(*s, Slot::Stopped) {
            drop(s);
            drop(made);
            (self.on_late_stop)();
        } else {
            *s = Slot::Up(made);
        }
    }
}

impl<T: Send + 'static> MdnsHolder<T> {
    /// Runs `advertise` on `rt` with a `Keeper` for what it starts.
    /// `on_late_stop` runs if an advertiser comes up after `stop`.
    pub fn spawn<A, Fut>(
        rt: &tokio::runtime::Handle,
        advertise: A,
        on_late_stop: impl Fn() + Send + Sync + 'static,
    ) -> Self
    where
        A: FnOnce(Keeper<T>) -> Fut,
        Fut: std::future::Future<Output = ()> + Send + 'static,
    {
        let slot = Arc::new(Mutex::new(Slot::Waiting));
        let keeper = Keeper { slot: slot.clone(), on_late_stop: Arc::new(on_late_stop) };
        let task = rt.spawn(advertise(keeper));
        Self { task, slot }
    }

    /// Whether the advertiser is up.
    pub fn is_advertising(&self) -> bool {
        matches!(*slot(&self.slot), Slot::Up(_))
    }

    /// Stops the waiting task and drops the advertiser (its goodbye goes
    /// out). `true` when one was up. A start still running finishes on its
    /// blocking thread and is dropped there (`Keeper`).
    pub fn stop(self) -> bool {
        let taken = std::mem::replace(&mut *slot(&self.slot), Slot::Stopped);
        self.task.abort();
        let was = matches!(taken, Slot::Up(_));
        drop(taken);
        was
    }
}

/// The process: single instance, host, tray. Exit code.
#[cfg(windows)]
pub fn run() -> i32 {
    use crate::platform::win32::Win32Platform;
    use crate::tray::instance::{self, Acquired};
    use crate::tray::win32 as tray;

    let _instance = match instance::acquire() {
        Ok(Acquired::First(guard)) => guard,
        Ok(Acquired::AlreadyRunning) => return 0,
        Err(e) => {
            tray::show_error(&e);
            return 1;
        }
    };
    let rt = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            tray::show_error(&format!("cannot start the async runtime: {e}"));
            return 1;
        }
    };
    let platform = match Win32Platform::new() {
        Ok(p) => p,
        Err(e) => {
            tray::show_error(&e.to_string());
            return 1;
        }
    };
    let paths = AppPaths::from_env(&|k| std::env::var(k).ok());
    let running = match rt.block_on(start(&paths, Arc::new(platform), StartOptions::default())) {
        Ok(r) => r,
        Err(e) => {
            tray::show_error(&e.to_string());
            return 1;
        }
    };
    let host = running.host.clone();
    let port = running.addr.port();
    let late = running.host.clone();
    let mdns = MdnsHolder::spawn(
        rt.handle(),
        move |keeper| async move {
            let read = || async { tokio::task::spawn_blocking(interface_ipv4s).await.unwrap_or_default() };
            let start = |a: &Advert| {
                let (a, k) = (a.clone(), keeper.clone());
                async move { k.start_blocking(move || crate::services::mdns_advertiser::MdnsAdvertiser::start(&a)).await }
            };
            advertise_when_ready(&host, port, read, &TokioSleeper, start).await
        },
        move || late.logs.ws(Severity::Info, "mDNS: stopped"),
    );
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("Quip.exe"));
    let app = tray::TrayApp {
        host: running.host.clone(),
        rt: rt.handle().clone(),
        exe,
        log_dir: paths.log_dir.clone(),
        port: running.addr.port(),
    };
    let code = match tray::run(app) {
        Ok(()) => 0,
        Err(e) => {
            tray::show_error(&e);
            1
        }
    };
    if mdns.stop() {
        running.host.logs.ws(Severity::Info, "mDNS: stopped");
    }
    // A start still under way finishes, is dropped and logs "mDNS: stopped"
    // (`Keeper`): give it a moment before the log is flushed.
    rt.shutdown_timeout(Duration::from_secs(2));
    running.host.flush();
    code
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::fake::FakePlatform;
    use crate::services::settings::Settings;
    use futures_util::StreamExt;

    fn paths(dir: &std::path::Path) -> AppPaths {
        AppPaths { config_dir: dir.join("Roaming").join("Quip"), log_dir: dir.join("Local").join("Quip").join("Logs") }
    }

    /// The real host listens on IPv4 only. Spec 3.1: on IPv6, a peer on the
    /// owner's /64 could hold all 8 of the network's pre-auth slots with
    /// queued wrong PINs (busy slots are never evicted) and refuse the owner.
    /// Fix that before listening on IPv6.
    #[test]
    fn the_real_host_listens_on_ipv4_only() {
        assert_eq!(StartOptions::default().bind_ip, IpAddr::V4(Ipv4Addr::UNSPECIFIED));
    }

    fn loopback() -> StartOptions {
        StartOptions { bind_ip: IpAddr::V4(Ipv4Addr::LOCALHOST), port: Some(0) }
    }

    fn saved(path: &std::path::Path) -> Settings {
        toml::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    #[tokio::test]
    async fn first_run_creates_settings_serves_and_persists_tray_changes() {
        let tmp = tempfile::tempdir().unwrap();
        let p = paths(tmp.path());
        let r = start(&p, Arc::new(FakePlatform::default()), loopback()).await.unwrap();
        assert_eq!(r.settings_path, p.config_dir.join("settings.toml"));
        let first = saved(&r.settings_path);
        assert_eq!(r.host.pin(), first.pin);
        assert_eq!(r.host.config.device_id, first.device_id);

        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{}", r.addr)).await.unwrap();
        let greeting = ws.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(greeting.contains("auth_required"), "{greeting}");

        r.host.set_pin("87654321".into());
        r.host.set_show_all_apps(true);
        r.host.flush();
        let after = saved(&r.settings_path);
        assert_eq!((after.pin.as_str(), after.show_all_apps), ("87654321", true));
        assert_eq!(after.device_id, first.device_id, "a new PIN keeps the device id");
        assert!(r.host.state().show_all_apps());
        assert!(std::fs::read_to_string(p.log_dir.join("websocket.log")).unwrap().contains("settings: created"));
    }

    /// Spec 8/9: every start's first `websocket.log` line names the build,
    /// before the settings line of a first run.
    #[tokio::test]
    async fn start_writes_the_stamp_line_first() {
        let tmp = tempfile::tempdir().unwrap();
        let p = paths(tmp.path());
        let r = start(&p, Arc::new(FakePlatform::default()), loopback()).await.unwrap();
        r.host.flush();
        let log = std::fs::read_to_string(p.log_dir.join("websocket.log")).unwrap();
        let first = log.lines().next().unwrap_or("");
        // The port asked for (0 here: any free one; 8765 by default).
        let want = format!("start: Quip for Windows {}, port 0", crate::build_info::BUILD);
        assert!(first.ends_with(&want), "first line {first:?}, want it to end with {want:?}\n{log}");
        assert!(log.contains("settings: created"), "{log}");
    }

    #[tokio::test]
    async fn a_second_start_keeps_the_pin_and_device_id() {
        let tmp = tempfile::tempdir().unwrap();
        let p = paths(tmp.path());
        let a = start(&p, Arc::new(FakePlatform::default()), loopback()).await.unwrap();
        let b = start(&p, Arc::new(FakePlatform::default()), loopback()).await.unwrap();
        assert_eq!(a.host.pin(), b.host.pin());
        assert_eq!(a.host.config.device_id, b.host.config.device_id);
    }

    #[tokio::test]
    async fn unreadable_settings_stop_the_start_and_mint_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let p = paths(tmp.path());
        // A folder where the file should be: every read fails, and not with
        // NotFound.
        std::fs::create_dir_all(p.config_dir.join("settings.toml")).unwrap();
        let err = start(&p, Arc::new(FakePlatform::default()), loopback()).await.err().unwrap();
        assert!(matches!(err, StartError::Settings(SettingsError::Unreadable { .. })), "{err:?}");
        assert!(err.to_string().contains("PIN and pairing are unchanged"));
        assert!(p.config_dir.join("settings.toml").is_dir());
        assert!(!p.config_dir.join("settings.toml.bad").exists());
    }

    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Records each wait; after `limit` waits it never wakes again (so a
    /// host that never finds a LAN address does not spin the test).
    struct CountingSleeper {
        waits: Mutex<Vec<Duration>>,
        limit: usize,
    }

    impl CountingSleeper {
        fn new(limit: usize) -> Self {
            Self { waits: Mutex::new(Vec::new()), limit }
        }
        fn waits(&self) -> Vec<Duration> {
            self.waits.lock().unwrap().clone()
        }
    }

    impl Sleeper for CountingSleeper {
        fn sleep(&self, d: Duration) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
            let mut w = self.waits.lock().unwrap();
            w.push(d);
            if w.len() > self.limit {
                Box::pin(std::future::pending())
            } else {
                Box::pin(async {})
            }
        }
    }

    /// Each call gives the next list; the last one repeats.
    fn addresses(lists: Vec<Vec<Ipv4Addr>>) -> (Arc<AtomicUsize>, impl FnMut() -> std::future::Ready<Vec<Ipv4Addr>>) {
        let reads = Arc::new(AtomicUsize::new(0));
        let r = reads.clone();
        let read = move || {
            let i = r.fetch_add(1, Ordering::SeqCst);
            std::future::ready(lists[i.min(lists.len() - 1)].clone())
        };
        (reads, read)
    }

    async fn started_host(dir: &std::path::Path) -> (Running, AppPaths) {
        let p = paths(dir);
        (start(&p, Arc::new(FakePlatform::default()), loopback()).await.unwrap(), p)
    }

    fn ws_log(r: &Running, p: &AppPaths) -> String {
        r.host.flush();
        std::fs::read_to_string(p.log_dir.join("websocket.log")).unwrap()
    }

    const LAN: Ipv4Addr = Ipv4Addr::new(192, 168, 1, 20);
    const TAILSCALE: Ipv4Addr = Ipv4Addr::new(100, 101, 1, 2);

    #[tokio::test]
    async fn a_lan_address_that_appears_later_is_advertised_once() {
        let tmp = tempfile::tempdir().unwrap();
        let (r, p) = started_host(tmp.path()).await;
        let (reads, read) = addresses(vec![vec![], vec![TAILSCALE], vec![LAN]]);
        let sleeper = CountingSleeper::new(100);
        let mut starts = Vec::new();
        let got = advertise_when_ready(&r.host, 8765, read, &sleeper, |a: &Advert| {
            starts.push(a.ips.clone());
            std::future::ready(Ok::<_, String>("advertiser"))
        })
        .await;
        assert_eq!(got, "advertiser");
        assert_eq!(starts, vec![vec![LAN]], "exactly one start, on the LAN address only");
        assert_eq!(reads.load(Ordering::SeqCst), 3);
        assert_eq!(sleeper.waits(), vec![MDNS_RETRY, MDNS_RETRY], "30 s between tries, none after");
        let log = ws_log(&r, &p);
        assert_eq!(log.matches("mDNS: no LAN address, not advertising yet").count(), 1, "the 1st try only: {log}");
        assert_eq!(
            log.matches("mDNS: LAN address found, advertising _quip._tcp on 1 LAN address(es), port 8765").count(),
            1,
            "{log}"
        );
    }

    #[tokio::test]
    async fn a_lan_address_at_start_is_advertised_at_once() {
        let tmp = tempfile::tempdir().unwrap();
        let (r, p) = started_host(tmp.path()).await;
        let (_, read) = addresses(vec![vec![LAN]]);
        let sleeper = CountingSleeper::new(100);
        advertise_when_ready(&r.host, 8765, read, &sleeper, |_: &Advert| std::future::ready(Ok::<_, String>(()))).await;
        assert!(sleeper.waits().is_empty(), "no wait before the first try");
        let log = ws_log(&r, &p);
        assert!(log.contains("mDNS: advertising _quip._tcp on 1 LAN address(es), port 8765 (did="), "{log}");
        assert!(!log.contains("no LAN address") && !log.contains("found"), "{log}");
    }

    #[tokio::test]
    async fn tailscale_only_never_starts_and_logs_every_tenth_try() {
        let tmp = tempfile::tempdir().unwrap();
        let (r, p) = started_host(tmp.path()).await;
        let (reads, read) = addresses(vec![vec![TAILSCALE]]);
        let sleeper = CountingSleeper::new(24);
        let mut starts = 0;
        let waited = tokio::time::timeout(
            Duration::from_millis(300),
            advertise_when_ready(&r.host, 8765, read, &sleeper, |_: &Advert| {
                starts += 1;
                std::future::ready(Ok::<_, String>(()))
            }),
        )
        .await;
        assert!(waited.is_err(), "it keeps waiting");
        assert_eq!(starts, 0);
        assert_eq!(reads.load(Ordering::SeqCst), 25);
        let log = ws_log(&r, &p);
        assert_eq!(log.matches("mDNS: no LAN address, not advertising yet").count(), 3, "tries 1, 10, 20: {log}");
        assert!(log.contains("(pair with the QR or the URL)") && log.contains("(try 20)"), "{log}");
    }

    #[tokio::test]
    async fn a_failed_start_is_retried() {
        let tmp = tempfile::tempdir().unwrap();
        let (r, p) = started_host(tmp.path()).await;
        let (_, read) = addresses(vec![vec![LAN]]);
        let sleeper = CountingSleeper::new(100);
        let mut tries = 0;
        let got = advertise_when_ready(&r.host, 8765, read, &sleeper, |_: &Advert| {
            tries += 1;
            std::future::ready(if tries < 3 { Err("mDNS register: boom".to_string()) } else { Ok(tries) })
        })
        .await;
        assert_eq!(got, 3);
        assert_eq!(sleeper.waits(), vec![MDNS_RETRY, MDNS_RETRY]);
        let log = ws_log(&r, &p);
        assert_eq!(log.matches("mDNS: not advertising: mDNS register: boom").count(), 1, "the 1st failure only: {log}");
        assert!(log.contains("mDNS: LAN address found, advertising"), "{log}");
    }

    #[tokio::test]
    async fn stop_ends_the_wait_and_nothing_starts_after() {
        let tmp = tempfile::tempdir().unwrap();
        let (r, _p) = started_host(tmp.path()).await;
        let starts = Arc::new(AtomicUsize::new(0));
        let gate = Arc::new(tokio::sync::Notify::new());
        let (host, s, g) = (r.host.clone(), starts.clone(), gate.clone());
        let holder = MdnsHolder::<()>::spawn(
            &tokio::runtime::Handle::current(),
            move |_keeper| async move {
                let sleeper = GatedSleeper(g);
                let (_, read) = addresses(vec![vec![], vec![LAN]]);
                advertise_when_ready(&host, 8765, read, &sleeper, |_: &Advert| {
                    s.fetch_add(1, Ordering::SeqCst);
                    std::future::ready(Ok::<_, String>(()))
                })
                .await
            },
            || {},
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!holder.is_advertising());
        assert!(!holder.stop(), "nothing was up");
        gate.notify_waiters();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(starts.load(Ordering::SeqCst), 0, "a stopped wait never starts Bonjour");
    }

    #[tokio::test]
    async fn stop_drops_an_advertiser_that_is_up() {
        let dropped = Arc::new(AtomicUsize::new(0));
        struct Advertiser(Arc<AtomicUsize>);
        impl Drop for Advertiser {
            fn drop(&mut self) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }
        let d = dropped.clone();
        let holder = MdnsHolder::spawn(
            &tokio::runtime::Handle::current(),
            move |k| async move { k.start_blocking(move || Ok(Advertiser(d))).await.unwrap() },
            || {},
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(holder.is_advertising());
        assert!(holder.stop());
        assert_eq!(dropped.load(Ordering::SeqCst), 1, "dropped, so its goodbye goes out");
    }

    /// R2 finding 7: a start that is still running when Quit stops the
    /// holder (it blocks, so `abort` cannot interrupt it) must not leave an
    /// advertiser up with nobody to stop it: it is dropped once it returns,
    /// and "mDNS: stopped" is still logged. It runs off the tokio workers,
    /// so this single-threaded runtime keeps going while it blocks.
    #[tokio::test]
    async fn a_start_that_finishes_after_stop_is_dropped_and_logged() {
        struct Advertiser(Arc<AtomicUsize>);
        impl Drop for Advertiser {
            fn drop(&mut self) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }
        let dropped = Arc::new(AtomicUsize::new(0));
        let late = Arc::new(AtomicUsize::new(0));
        let (started_tx, started_rx) = std::sync::mpsc::channel::<()>();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let (d, l) = (dropped.clone(), late.clone());
        let holder = MdnsHolder::spawn(
            &tokio::runtime::Handle::current(),
            move |k| async move {
                let _ = k
                    .start_blocking(move || {
                        let _ = started_tx.send(());
                        let _ = release_rx.recv_timeout(Duration::from_secs(5));
                        Ok(Advertiser(d))
                    })
                    .await;
            },
            move || {
                l.fetch_add(1, Ordering::SeqCst);
            },
        );
        // The start is blocking now; the test's own (only) worker is free.
        tokio::task::spawn_blocking(move || started_rx.recv_timeout(Duration::from_secs(5))).await.unwrap().unwrap();
        assert!(!holder.is_advertising());
        assert!(!holder.stop(), "nothing was up yet");
        release_tx.send(()).unwrap();
        for _ in 0..100 {
            if late.load(Ordering::SeqCst) > 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(late.load(Ordering::SeqCst), 1, "\"mDNS: stopped\" is logged for the late one");
        assert_eq!(dropped.load(Ordering::SeqCst), 1, "dropped at once, so its goodbye goes out");
    }

    /// Each wait ends when the test notifies.
    struct GatedSleeper(Arc<tokio::sync::Notify>);

    impl Sleeper for GatedSleeper {
        fn sleep(&self, _: Duration) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
            let g = self.0.clone();
            Box::pin(async move { g.notified().await })
        }
    }

    #[tokio::test]
    async fn a_busy_port_is_a_bind_error() {
        let tmp = tempfile::tempdir().unwrap();
        let p = paths(tmp.path());
        let taken = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let opts = StartOptions { port: Some(taken.local_addr().unwrap().port()), ..loopback() };
        let err = start(&p, Arc::new(FakePlatform::default()), opts).await.err().unwrap();
        assert!(matches!(err, StartError::Bind(BindError::PortInUse(_))), "{err:?}");
    }
}
