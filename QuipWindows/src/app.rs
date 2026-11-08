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
//! Win32 platform, Bonjour (`advertise`, stopped on Quit), then the tray
//! loop on the main thread. Every error before
//! the tray is up is shown in a message box (there is no console).

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;

use crate::host::{ConnectionLimits, Host, HostConfig, HostParts, Ticks, TokioSleeper};
use crate::platform::traits::Platform;
use crate::services::clock::SystemClock;
use crate::services::local_addresses::{interface_ipv4s, websocket_urls};
use crate::services::log_paths::{default_config_dir, LogPaths};
use crate::services::logs::Logs;
use crate::services::mdns_advertiser::{Advert, MdnsAdvertiser};
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

/// Advertises the running host over Bonjour on `addresses` (spec 3.1).
/// Every outcome is logged to websocket.log; a failure leaves the host
/// running (the phone still connects by its saved or scanned URL). Only the
/// real app calls this: `--fake-platform` never advertises.
pub fn advertise(host: &Host, addresses: &[Ipv4Addr], port: u16) -> Option<MdnsAdvertiser> {
    let did_prefix: String = host.config.device_id.chars().take(8).collect();
    let Some(advert) = Advert::new(&host.config.display_name, addresses, port, &host.config.device_id) else {
        host.logs.ws(Severity::Warn, "mDNS: no LAN address, not advertising (pair with the QR or the URL)");
        return None;
    };
    match MdnsAdvertiser::start(&advert) {
        Ok(a) => {
            host.logs.ws(
                Severity::Info,
                &format!(
                    "mDNS: advertising _quip._tcp on {} LAN address(es), port {port} (did={did_prefix})",
                    advert.ips.len()
                ),
            );
            Some(a)
        }
        Err(e) => {
            host.logs.ws(Severity::Error, &format!("mDNS: not advertising: {e}"));
            None
        }
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
    let advertiser = advertise(&running.host, &interface_ipv4s(), running.addr.port());
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
    if advertiser.is_some() {
        drop(advertiser);
        running.host.logs.ws(Severity::Info, "mDNS: stopped");
    }
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

    #[tokio::test]
    async fn no_lan_address_is_logged_and_nothing_is_advertised() {
        let tmp = tempfile::tempdir().unwrap();
        let p = paths(tmp.path());
        let r = start(&p, Arc::new(FakePlatform::default()), loopback()).await.unwrap();
        let tailscale_only = [Ipv4Addr::new(100, 101, 1, 2)];
        assert!(advertise(&r.host, &tailscale_only, r.addr.port()).is_none());
        r.host.flush();
        let log = std::fs::read_to_string(p.log_dir.join("websocket.log")).unwrap();
        assert!(log.contains("mDNS: no LAN address, not advertising"), "{log}");
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
