//! `Quip --fake-platform` (spec 10.6): the real server, on the Mac, against
//! `platform::fake` and `tools/fake-windows/fixture.json`, so the phone can be
//! checked in a simulator without a PC.
//!
//! Every `tools/fake-mac/README.md` safety rule is enforced here:
//! - 127.0.0.1 only (bind and peer check); never port 8765;
//!   a busy port fails to bind;
//! - no mDNS (this build has none at all);
//! - fixed fake device id (`device_id::FAKE_DEVICE_ID`) and monitor name
//!   `FakeWindows Display`, which no real host can have;
//! - no stored secrets: settings are not read or written, phone PINs are
//!   logged by length only, `preferences_snapshot` is dropped (key names
//!   logged) and `preferences_request` always gets "no backup";
//! - logs go to a temp folder, never `%LOCALAPPDATA%` or the Mac's logs: a
//!   `--log-dir` inside `~/Library/Logs/Quip` or `%LOCALAPPDATA%\Quip` is
//!   refused (`validate_log_dir`);
//! - every platform action the fake performs is printed to stdout, one line
//!   each, counts only (`FakePlatform::set_echo`), so a tap can be verified.

use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::io::AsyncBufReadExt;

use crate::host::{ConnectionLimits, Host, HostConfig, HostParts, Ticks, TokioSleeper};
use crate::platform::fake::{window_from_fixture, FakePlatform, Fixture, FixtureRect, FixtureWindow};
use crate::platform::traits::InputAccess;
use crate::services::clock::SystemClock;
use crate::services::device_id::FAKE_DEVICE_ID;
use crate::services::layout::PixelRect;
use crate::services::log_paths::LogPaths;
use crate::services::logs::Logs;
use crate::services::pairing::PairingPayload;
use crate::services::prefs_store::PrefsStore;
use crate::services::ws_server::{self, LISTEN_PORT};

pub const DEFAULT_PORT: u16 = 8797;
pub const DEFAULT_PIN: &str = "11112222";
/// The only primary-display name the fake accepts. The phone treats an equal
/// monitor name as "same host" evidence.
pub const FAKE_MONITOR: &str = "FakeWindows Display";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FakeArgs {
    pub port: u16,
    pub pin: String,
    pub fixture: Option<PathBuf>,
    pub log_dir: Option<PathBuf>,
}

pub const USAGE: &str = "usage: Quip --fake-platform [--port N] [--pin PIN] [--fixture PATH] [--log-dir DIR]";

/// Parse the arguments after `--fake-platform`.
pub fn parse_args(args: &[String]) -> Result<FakeArgs, String> {
    let mut a = FakeArgs { port: DEFAULT_PORT, pin: DEFAULT_PIN.into(), fixture: None, log_dir: None };
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let mut value = || it.next().cloned().ok_or_else(|| format!("{flag} needs a value\n{USAGE}"));
        match flag.as_str() {
            "--port" => {
                let v = value()?;
                a.port = v.parse().map_err(|_| format!("--port: not a port: {v}"))?;
            }
            "--pin" => a.pin = value()?,
            "--fixture" => a.fixture = Some(PathBuf::from(value()?)),
            "--log-dir" => a.log_dir = Some(PathBuf::from(value()?)),
            "--fake-platform" => {}
            other => return Err(format!("unknown option {other}\n{USAGE}")),
        }
    }
    validate_port(a.port)?;
    if let Some(d) = &a.log_dir {
        validate_log_dir(d, &|k| std::env::var(k).ok())?;
    }
    if a.pin.is_empty() || !a.pin.chars().all(|c| c.is_ascii_digit()) {
        return Err("--pin must be digits".into());
    }
    Ok(a)
}

/// Never the real app's port, never "any port".
pub fn validate_port(port: u16) -> Result<(), String> {
    if port == LISTEN_PORT {
        return Err(format!("port {LISTEN_PORT} is the real Quip's port; the fake refuses it"));
    }
    if port == 0 {
        return Err("port 0 is not allowed: the phone needs a port it can be told".into());
    }
    Ok(())
}

/// `path` made absolute and free of `.` / `..`, with the part that exists
/// resolved through symlinks (so `/tmp/link -> ~/Library/Logs/Quip` is
/// caught). Lower-cased: macOS and Windows file systems ignore case.
fn normalized(path: &Path) -> String {
    let abs = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map(|c| c.join(path)).unwrap_or_else(|_| path.to_path_buf())
    };
    let mut clean = PathBuf::new();
    for c in abs.components() {
        match c {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                clean.pop();
            }
            other => clean.push(other),
        }
    }
    // Resolve the longest existing prefix.
    let mut existing = clean.clone();
    let mut rest = Vec::new();
    while !existing.exists() {
        match (existing.file_name().map(|n| n.to_os_string()), existing.parent().map(Path::to_path_buf)) {
            (Some(name), Some(parent)) => {
                rest.push(name);
                existing = parent;
            }
            _ => break,
        }
    }
    let mut out = std::fs::canonicalize(&existing).unwrap_or(existing);
    for r in rest.into_iter().rev() {
        out.push(r);
    }
    out.to_string_lossy().replace('\\', "/").trim_end_matches('/').to_lowercase()
}

/// The real apps' log folders: the Mac's `~/Library/Logs/Quip` and the
/// Windows host's `%LOCALAPPDATA%\Quip` (logs and settings live there).
pub fn forbidden_log_roots(env: &dyn Fn(&str) -> Option<String>) -> Vec<PathBuf> {
    let mut v = vec![];
    if let Some(home) = env("HOME") {
        v.push(Path::new(&home).join("Library").join("Logs").join("Quip"));
    }
    if let Some(local) = env("LOCALAPPDATA") {
        v.push(Path::new(&local).join("Quip"));
    }
    v
}

/// Refuse a `--log-dir` inside a real app's log folder: the fake's lines
/// would land in the owner's diagnostics.
pub fn validate_log_dir(dir: &Path, env: &dyn Fn(&str) -> Option<String>) -> Result<(), String> {
    let d = normalized(dir);
    for root in forbidden_log_roots(env) {
        let r = normalized(&root);
        if d == r || d.starts_with(&format!("{r}/")) {
            return Err(format!(
                "--log-dir {} is inside the real Quip's logs ({}); the fake refuses it",
                dir.display(),
                root.display()
            ));
        }
    }
    Ok(())
}

/// The fixture must not be mistakable for a real host.
pub fn validate_fixture(f: &Fixture) -> Result<(), String> {
    let primary = f.displays.iter().find(|d| d.is_primary).map(|d| d.name.as_str());
    if primary != Some(FAKE_MONITOR) {
        return Err(format!("the fixture's primary display must be named {FAKE_MONITOR:?} (got {primary:?})"));
    }
    Ok(())
}

pub fn default_fixture_path() -> PathBuf {
    // An explicit override lets a copied tree (cargo-mutants builds in a temp
    // copy of this crate only) still find the repo's fixture.
    if let Ok(p) = std::env::var("QUIP_FAKE_WINDOWS_FIXTURE") {
        return PathBuf::from(p);
    }
    let here = Path::new("tools/fake-windows/fixture.json");
    if here.exists() {
        return here.to_path_buf();
    }
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("tools").join("fake-windows").join("fixture.json")
}

pub fn default_log_dir() -> PathBuf {
    std::env::temp_dir().join("quip-fake-windows").join("Logs")
}

/// The loopback URL the phone pairs with.
pub fn url(port: u16) -> String {
    format!("ws://127.0.0.1:{port}")
}

/// A running fake: the host, the scripted platform, the bound address.
pub struct FakeHost {
    pub host: Arc<Host>,
    pub platform: FakePlatform,
    pub addr: SocketAddr,
}

/// Build and start (bind + serve). `ticks` is `Auto` for the CLI.
pub async fn start(args: &FakeArgs, ticks: Ticks) -> Result<FakeHost, String> {
    validate_port(args.port)?;
    if let Some(d) = &args.log_dir {
        validate_log_dir(d, &|k| std::env::var(k).ok())?;
    }
    let path = args.fixture.clone().unwrap_or_else(default_fixture_path);
    // Off the reactor (spec 10.1), like every other file read.
    let p2 = path.clone();
    let text = tokio::task::spawn_blocking(move || std::fs::read_to_string(p2))
        .await
        .map_err(|e| format!("cannot read fixture {}: {e}", path.display()))?
        .map_err(|e| format!("cannot read fixture {}: {e}", path.display()))?;
    let fixture = Fixture::parse(&text)?;
    validate_fixture(&fixture)?;
    let platform = FakePlatform::from_fixture(&fixture);
    platform.set_echo(true);
    let clock = SystemClock::shared();
    let logs = Logs::new(LogPaths::new(args.log_dir.clone().unwrap_or_else(default_log_dir)), clock.clone(), true);
    let host = Host::new(HostParts {
        config: HostConfig {
            device_id: FAKE_DEVICE_ID.into(),
            display_name: fixture.display_name.clone().unwrap_or_else(|| "Fake Windows (QA)".into()),
            local_urls: vec![url(args.port)],
            loopback_only: true,
            ticks,
            limits: ConnectionLimits::default(),
        },
        platform: Arc::new(platform.clone()),
        clock,
        logs,
        pin: args.pin.clone(),
        prefs: PrefsStore::NoBackup,
        settings: None,
        sleeper: Arc::new(TokioSleeper),
    })
    .map_err(|e| format!("cannot start platform threads: {e}"))?;
    host.poll_tick().await;
    let listener =
        ws_server::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, args.port))).await.map_err(|e| e.to_string())?;
    let addr = listener.local_addr().map_err(|e| e.to_string())?;
    ws_server::spawn(host.clone(), listener);
    Ok(FakeHost { host, platform, addr })
}

/// Resolve `<window>`: a handle, a wire id, or a unique piece of a title.
pub fn find_window(platform: &FakePlatform, host: &Host, needle: &str) -> Result<u64, String> {
    if let Ok(h) = needle.parse::<u64>() {
        if platform.windows().iter().any(|w| w.handle == h) {
            return Ok(h);
        }
    }
    if let Some(w) = host.state().find_tracked(needle) {
        return Ok(w.platform.handle);
    }
    let lower = needle.to_lowercase();
    let hits: Vec<_> = platform.windows().into_iter().filter(|w| w.title.to_lowercase().contains(&lower)).collect();
    match hits.as_slice() {
        [one] => Ok(one.handle),
        [] => Err(format!("no such window: {needle}")),
        many => Err(format!(
            "ambiguous: {}",
            many.iter().map(|w| format!("{} ({})", w.handle, w.title)).collect::<Vec<_>>().join(", ")
        )),
    }
}

pub const HELP: &str = "commands:
  help                         this list
  status                       phones, windows, foreground
  layout                       re-poll and resend layout_update if it changed
  open <title> [cmd|app]       add a window (default: Windows Terminal running pwsh)
  close <window>               remove a window
  move <window> X Y W H        move/resize (visible rect, px)
  title <window> <text>        retitle
  front <window>|none          change the foreground window
  refuse <window> on|off       make focus fail for it
  minimize <window>            minimize it (no border until restored, as DWM)
  maximize <window>            maximize it
  refuse-move <window> on|off  make arrange fail to move it (an elevated window)
  rescale <window> <percent>   its next move lands scaled (another monitor's DPI)
  min-size <window> W H        it keeps an outer size of at least W x H
  run <window> <exe>...|shell  start a program in its shell (run 3 python.exe), or back to the shell
  block <ms>|off               block typing (hang-guard check)
  uipi <n>|off                 let only n units per batch in (the short-count guard)
  elevated <window> on|off|unknown  its integrity level is above Quip's (or unreadable): no input
  quit                         exit
<window> = handle, wire id, or a unique piece of the title";

/// One stdin command. Returns `false` on `quit`.
pub async fn command(fake: &FakeHost, line: &str, next_handle: &mut u64) -> bool {
    let parts: Vec<&str> = line.split_whitespace().collect();
    let (p, h) = (&fake.platform, &fake.host);
    let say = |s: String| eprintln!("{s}");
    match parts.as_slice() {
        [] => {}
        ["help"] => say(HELP.into()),
        ["quit"] | ["exit"] => return false,
        ["status"] => {
            say(format!("phones authenticated: {}", h.authenticated_count()));
            say(format!("foreground: {:?}", p.foreground()));
            for w in h.state().windows() {
                say(format!(
                    "  {} handle={} {:?} app={:?} shell={} enabled={} minimized={}",
                    w.id,
                    w.platform.handle,
                    w.platform.title,
                    w.platform.app,
                    w.platform.shell.map(|s| s.as_str()).unwrap_or("-"),
                    w.enabled,
                    w.platform.is_minimized
                ));
            }
        }
        ["layout"] => h.poll_tick().await,
        ["open", rest @ ..] if !rest.is_empty() => {
            let (kind, title_parts) = match rest.last() {
                Some(&"cmd") => ("cmd", &rest[..rest.len() - 1]),
                Some(&"app") => ("app", &rest[..rest.len() - 1]),
                _ => ("wt", rest),
            };
            let title = title_parts.join(" ");
            *next_handle += 1;
            let fw = FixtureWindow {
                handle: *next_handle,
                pid: 9000 + (*next_handle as u32 % 1000),
                title: if title.is_empty() { "New window".into() } else { title },
                class_name: match kind {
                    "cmd" => "ConsoleWindowClass".into(),
                    "app" => "Notepad".into(),
                    _ => "CASCADIA_HOSTING_WINDOW_CLASS".into(),
                },
                exe_path: Some(match kind {
                    "cmd" => r"C:\Windows\System32\conhost.exe".into(),
                    "app" => r"C:\Windows\System32\notepad.exe".into(),
                    _ => r"C:\Program Files\WindowsApps\WindowsTerminal.exe".into(),
                }),
                product_name: (kind == "app").then(|| "Notepad".to_string()),
                shells: match kind {
                    "cmd" => vec!["cmd.exe".into()],
                    "app" => vec![],
                    _ => vec!["pwsh.exe".into()],
                },
                visible: FixtureRect { x: 200, y: 150, width: 900, height: 600 },
                border: 7,
                is_minimized: false,
            };
            p.add_window(window_from_fixture(&fw));
            say(format!("opened handle={}", fw.handle));
            h.poll_tick().await;
        }
        ["close", w] => match find_window(p, h, w) {
            Ok(handle) => {
                p.remove_window(handle);
                h.poll_tick().await;
            }
            Err(e) => say(e),
        },
        ["move", w, x, y, wd, ht] => {
            let nums: Result<Vec<i32>, _> = [x, y, wd, ht].iter().map(|s| s.parse::<i32>()).collect();
            match (find_window(p, h, w), nums) {
                (Ok(handle), Ok(n)) => {
                    p.move_window(handle, PixelRect::new(n[0], n[1], n[2], n[3]));
                    h.poll_tick().await;
                }
                (Err(e), _) => say(e),
                (_, Err(_)) => say("move: X Y W H must be integers".into()),
            }
        }
        ["title", w, rest @ ..] if !rest.is_empty() => match find_window(p, h, w) {
            Ok(handle) => {
                p.set_title(handle, &rest.join(" "));
                h.poll_tick().await;
            }
            Err(e) => say(e),
        },
        ["front", "none"] => {
            p.set_foreground(None);
            h.poll_tick().await;
        }
        ["front", w] => match find_window(p, h, w) {
            Ok(handle) => {
                p.set_foreground(Some(handle));
                h.poll_tick().await;
            }
            Err(e) => say(e),
        },
        ["refuse", w, onoff] => match find_window(p, h, w) {
            Ok(handle) => p.set_refuse_focus(handle, *onoff == "on"),
            Err(e) => say(e),
        },
        ["minimize", w] => match find_window(p, h, w) {
            Ok(handle) => {
                p.set_minimized(handle, true);
                p.set_border_after_restore(handle, 7);
                h.poll_tick().await;
            }
            Err(e) => say(e),
        },
        ["maximize", w] => match find_window(p, h, w) {
            Ok(handle) => {
                p.set_maximized(handle, true);
                h.poll_tick().await;
            }
            Err(e) => say(e),
        },
        ["refuse-move", w, onoff @ ("on" | "off")] => match find_window(p, h, w) {
            Ok(handle) => p.set_refuse_move(handle, *onoff == "on"),
            Err(e) => say(e),
        },
        ["rescale", w, pct] => match (find_window(p, h, w), pct.parse::<i32>()) {
            (Ok(handle), Ok(pct)) if pct > 0 => p.set_rescale_once(handle, pct),
            (Err(e), _) => say(e),
            _ => say("rescale: <window> <percent>".into()),
        },
        ["min-size", w, wd, ht] => match (find_window(p, h, w), wd.parse::<i32>(), ht.parse::<i32>()) {
            (Ok(handle), Ok(wd), Ok(ht)) => p.set_min_size(handle, wd, ht),
            (Err(e), _, _) => say(e),
            _ => say("min-size: <window> W H".into()),
        },
        ["run", w, "shell"] => match find_window(p, h, w) {
            Ok(handle) => {
                let shell = h
                    .state()
                    .find_tracked_by_handle(handle)
                    .and_then(|t| t.platform.shell)
                    .map(|s| format!("{}.exe", s.as_str()))
                    .unwrap_or_default();
                p.set_running(handle, &[shell.as_str()]);
            }
            Err(e) => say(e),
        },
        ["run", w, programs @ ..] if !programs.is_empty() => match find_window(p, h, w) {
            Ok(handle) => {
                let shell = h
                    .state()
                    .find_tracked_by_handle(handle)
                    .and_then(|t| t.platform.shell)
                    .map(|s| format!("{}.exe", s.as_str()))
                    .unwrap_or_else(|| "pwsh.exe".into());
                let mut all = vec![shell.as_str()];
                all.extend(programs.iter().copied());
                p.set_running(handle, &all);
            }
            Err(e) => say(e),
        },
        ["elevated", w, mode @ ("on" | "off" | "unknown")] => match find_window(p, h, w) {
            Ok(handle) => p.set_input_access(
                handle,
                match *mode {
                    "on" => InputAccess::Elevated,
                    "unknown" => InputAccess::Unknown,
                    _ => InputAccess::Allowed,
                },
            ),
            Err(e) => say(e),
        },
        ["elevated", ..] => say("elevated: <window> on|off|unknown".into()),
        ["uipi", "off"] => p.set_input_limit(None),
        ["uipi", n] => match n.parse::<usize>() {
            Ok(n) => p.set_input_limit(Some(n)),
            Err(_) => say("uipi: <n>|off".into()),
        },
        ["block", "off"] => p.set_block_typing(None),
        ["block", ms] => match ms.parse::<u64>() {
            Ok(ms) => p.set_block_typing(Some(std::time::Duration::from_millis(ms))),
            Err(_) => say("block: <ms>|off".into()),
        },
        _ => say(format!("unknown command: {line} (try help)")),
    }
    true
}

/// The CLI entry point. Exit code.
pub async fn run(args: Vec<String>) -> i32 {
    let a = match parse_args(&args) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            return 2;
        }
    };
    let fake = match start(&a, Ticks::Auto).await {
        Ok(f) => f,
        Err(e) => {
            eprintln!("fake-windows: {e}");
            return 1;
        }
    };
    let link = PairingPayload::new(url(fake.addr.port()), a.pin.clone()).encoded_url();
    eprintln!("fake-windows listening on {} (loopback only), PIN {}", fake.addr, a.pin);
    eprintln!(
        "device id {FAKE_DEVICE_ID}, monitor {FAKE_MONITOR:?}, logs in {}",
        fake.host.logs.paths().dir().display()
    );
    eprintln!("pair a simulator:\n  xcrun simctl openurl <udid> '{link}'");
    eprintln!("type 'help' for commands");
    let mut next_handle = fake.platform.windows().iter().map(|w| w.handle).max().unwrap_or(0x1000);
    let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
    loop {
        tokio::select! {
            line = lines.next_line() => match line {
                Ok(Some(l)) => if !command(&fake, &l, &mut next_handle).await { break },
                // stdin closed: keep serving until Ctrl-C.
                Ok(None) | Err(_) => { let _ = tokio::signal::ctrl_c().await; break; }
            },
            _ = tokio::signal::ctrl_c() => break,
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn defaults_are_safe() {
        let a = parse_args(&[]).unwrap();
        assert_eq!(a.port, DEFAULT_PORT);
        assert_ne!(a.port, LISTEN_PORT);
        assert_eq!(a.pin, DEFAULT_PIN);
    }

    #[test]
    fn port_8765_and_0_are_refused() {
        assert!(parse_args(&s(&["--port", "8765"])).unwrap_err().contains("8765"));
        assert!(parse_args(&s(&["--port", "0"])).is_err());
        assert!(parse_args(&s(&["--port", "x"])).is_err());
        assert!(validate_port(8799).is_ok());
    }

    #[test]
    fn options_parse() {
        let a = parse_args(&s(&["--port", "8790", "--pin", "12345678", "--fixture", "f.json", "--log-dir", "/tmp/x"]))
            .unwrap();
        assert_eq!(a.port, 8790);
        assert_eq!(a.fixture, Some(PathBuf::from("f.json")));
        assert!(parse_args(&s(&["--bogus"])).is_err());
        assert!(parse_args(&s(&["--pin"])).is_err());
        assert!(parse_args(&s(&["--pin", "12ab"])).is_err());
    }

    #[test]
    fn shipped_fixture_is_valid_and_fake() {
        let text = std::fs::read_to_string(default_fixture_path()).unwrap();
        let f = Fixture::parse(&text).unwrap();
        validate_fixture(&f).unwrap();
        assert!(f.windows.len() >= 4);
        assert!(f.displays.len() <= 2);
    }

    #[test]
    fn a_fixture_named_like_a_real_display_is_refused() {
        let f = Fixture::parse(
            r#"{"displays":[{"deviceName":"d","name":"DELL U2720Q","bounds":{"x":0,"y":0,"width":1,"height":1},
                "workArea":{"x":0,"y":0,"width":1,"height":1},"isPrimary":true}],"windows":[]}"#,
        )
        .unwrap();
        assert!(validate_fixture(&f).is_err());
    }

    #[test]
    fn a_log_dir_inside_the_real_logs_is_refused() {
        let home = tempfile::tempdir().unwrap();
        let local = tempfile::tempdir().unwrap();
        let (h, l) = (home.path().to_string_lossy().to_string(), local.path().to_string_lossy().to_string());
        let env = move |k: &str| match k {
            "HOME" => Some(h.clone()),
            "LOCALAPPDATA" => Some(l.clone()),
            _ => None,
        };
        let mac = home.path().join("Library").join("Logs").join("Quip");
        for bad in [
            mac.clone(),
            mac.join("fake"),
            home.path().join("Library/Logs/x/../Quip/sub"),
            home.path().join("library/logs/QUIP"),
            local.path().join("Quip"),
            local.path().join("Quip").join("Logs"),
        ] {
            assert!(validate_log_dir(&bad, &env).is_err(), "{}", bad.display());
        }
        for ok in [home.path().join("Library/Logs/QuipFake"), home.path().join("x"), local.path().join("Quipx")] {
            assert!(validate_log_dir(&ok, &env).is_ok(), "{}", ok.display());
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_into_the_real_logs_is_refused() {
        let home = tempfile::tempdir().unwrap();
        let real = home.path().join("Library").join("Logs").join("Quip");
        std::fs::create_dir_all(&real).unwrap();
        let link = home.path().join("innocent");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let h = home.path().to_string_lossy().to_string();
        let env = move |k: &str| (k == "HOME").then(|| h.clone());
        assert!(validate_log_dir(&link.join("sub"), &env).is_err());
    }

    #[test]
    fn parse_args_refuses_the_real_log_dir() {
        if let Ok(home) = std::env::var("HOME") {
            let bad = format!("{home}/Library/Logs/Quip");
            assert!(parse_args(&s(&["--log-dir", &bad])).unwrap_err().contains("refuses"));
        }
    }

    #[test]
    fn default_log_dir_is_a_temp_folder() {
        let d = default_log_dir();
        assert!(d.starts_with(std::env::temp_dir()));
        assert!(d.ends_with(Path::new("quip-fake-windows").join("Logs")));
    }

    async fn scripted() -> (FakeHost, tempfile::TempDir) {
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let logs = tempfile::tempdir().unwrap();
        let args = FakeArgs {
            port,
            pin: DEFAULT_PIN.into(),
            fixture: Some(default_fixture_path()),
            log_dir: Some(logs.path().to_path_buf()),
        };
        (start(&args, Ticks::Manual).await.unwrap(), logs)
    }

    #[tokio::test]
    async fn console_commands_drive_the_fake_pc() {
        use crate::platform::traits::{InputBackend, WindowBackend, WindowRef};
        use crate::services::multiline_policy::Shell;
        let (f, _logs) = scripted().await;
        let p = f.platform.clone();
        let mut next = 5000;
        let n0 = p.windows().len();
        for line in ["", "help", "status", "layout", "bogus command"] {
            assert!(command(&f, line, &mut next).await, "{line:?}");
        }
        assert!(!command(&f, "quit", &mut next).await);
        assert!(!command(&f, "exit", &mut next).await);
        assert!(command(&f, "open alpha beta", &mut next).await);
        assert!(command(&f, "open gamma cmd", &mut next).await);
        assert!(command(&f, "open delta app", &mut next).await);
        assert!(command(&f, "open", &mut next).await, "no title: unknown command");
        let ws = p.windows();
        assert_eq!(ws.len(), n0 + 3);
        let by = |h: u64| ws.iter().find(|w| w.handle == h).unwrap().clone();
        let (a, g, d) = (by(5001), by(5002), by(5003));
        assert_eq!(
            (a.title.as_str(), a.class_name.as_str(), a.pid),
            ("alpha beta", "CASCADIA_HOSTING_WINDOW_CLASS", 9001)
        );
        assert_eq!(
            (g.title.as_str(), g.class_name.as_str(), g.shell),
            ("gamma", "ConsoleWindowClass", Some(Shell::Cmd))
        );
        assert_eq!((d.title.as_str(), d.app.as_str(), d.terminal), ("delta", "Notepad", None));
        assert_eq!(next, 5003);
        assert_eq!(g.exe_path.as_deref(), Some(r"C:\Windows\System32\conhost.exe"));
        assert_eq!(d.exe_path.as_deref(), Some(r"C:\Windows\System32\notepad.exe"));
        assert_eq!(p.current_shell(g.window_ref()), Ok(Some(Shell::Cmd)));
        let ra = a.window_ref();

        command(&f, "title 5001 renamed one", &mut next).await;
        command(&f, "title 5001", &mut next).await; // no text: unknown command, title kept
        command(&f, "move alpha 1 2 300 400", &mut next).await; // stale title: not found
        command(&f, "move 5001 1 2 300 400", &mut next).await;
        command(&f, "move 5001 1 2 x 400", &mut next).await;
        let a = p.windows().into_iter().find(|w| w.handle == 5001).unwrap();
        assert_eq!(a.title, "renamed one");
        assert_eq!(a.visible, PixelRect::new(1, 2, 300, 400));

        command(&f, "front 5002", &mut next).await;
        assert_eq!(p.foreground(), Some(5002));
        command(&f, "front none", &mut next).await;
        assert_eq!(p.foreground(), None);
        let id = f.host.state().find_tracked_by_handle(5001).unwrap().id.clone();
        command(&f, &format!("front {id}"), &mut next).await;
        assert_eq!(p.foreground(), Some(5001), "by wire id");

        command(&f, "refuse renamed on", &mut next).await;
        assert!(p.bring_to_foreground(ra).is_err());
        command(&f, "refuse renamed off", &mut next).await;
        assert!(p.bring_to_foreground(ra).is_ok());

        command(&f, "run 5001 python.exe", &mut next).await;
        assert_eq!(p.current_shell(ra), Ok(Some(Shell::Unknown)));
        command(&f, "run 5001 shell", &mut next).await;
        assert_eq!(p.current_shell(ra), Ok(Some(Shell::Pwsh)));
        command(&f, "run 5001", &mut next).await;
        assert_eq!(p.current_shell(ra), Ok(Some(Shell::Pwsh)), "no program: unknown command");

        assert_eq!(p.input_access(ra), Ok(InputAccess::Allowed));
        command(&f, "elevated 5001 on", &mut next).await;
        assert_eq!(p.input_access(ra), Ok(InputAccess::Elevated));
        command(&f, "elevated 5001 unknown", &mut next).await;
        assert_eq!(p.input_access(ra), Ok(InputAccess::Unknown));
        command(&f, "elevated 5001 maybe", &mut next).await;
        command(&f, "elevated nothing-like-this on", &mut next).await;
        assert_eq!(p.input_access(ra), Ok(InputAccess::Unknown));
        command(&f, "elevated 5001 off", &mut next).await;
        assert_eq!(p.input_access(ra), Ok(InputAccess::Allowed));

        command(&f, "uipi 0", &mut next).await;
        assert_eq!(p.send_units(ra, &[0x61]), Ok(0));
        command(&f, "uipi x", &mut next).await;
        command(&f, "uipi off", &mut next).await;
        assert_eq!(p.send_units(ra, &[0x61]), Ok(1));

        command(&f, "block 150", &mut next).await;
        let t0 = std::time::Instant::now();
        let _ = p.send_units(ra, &[0x61]);
        assert!(t0.elapsed() >= std::time::Duration::from_millis(150));
        command(&f, "block nope", &mut next).await;
        command(&f, "block off", &mut next).await;
        let t0 = std::time::Instant::now();
        let _ = p.send_units(ra, &[0x61]);
        assert!(t0.elapsed() < std::time::Duration::from_millis(100));

        command(&f, "minimize 5001", &mut next).await;
        let a = p.windows().into_iter().find(|w| w.handle == 5001).unwrap();
        assert!(a.is_minimized && a.outer == a.visible, "minimized, no border until restored");
        command(&f, "maximize 5002", &mut next).await;
        assert!(p.windows().into_iter().find(|w| w.handle == 5002).unwrap().is_maximized);
        command(&f, "refuse-move 5002 on", &mut next).await;
        let mv = |h: u64| crate::platform::traits::WindowMove {
            window: p.windows().into_iter().find(|w| w.handle == h).unwrap().window_ref(),
            outer: PixelRect::new(0, 0, 500, 400),
        };
        assert!(p.move_windows(&[mv(5002)])[0].is_err());
        command(&f, "refuse-move 5002 maybe", &mut next).await;
        command(&f, "refuse-move 5002 off", &mut next).await;
        assert!(p.move_windows(&[mv(5002)])[0].is_ok());
        command(&f, "rescale 5002 150", &mut next).await;
        command(&f, "rescale 5002 x", &mut next).await;
        command(&f, "rescale nothing-like-this 150", &mut next).await;
        p.move_windows(&[mv(5002)]);
        assert_eq!(p.windows().into_iter().find(|w| w.handle == 5002).unwrap().outer, PixelRect::new(0, 0, 750, 600));
        command(&f, "min-size 5002 900 x", &mut next).await;
        command(&f, "min-size 5002 900 800", &mut next).await;
        p.move_windows(&[mv(5002)]);
        assert_eq!(p.windows().into_iter().find(|w| w.handle == 5002).unwrap().outer, PixelRect::new(0, 0, 900, 800));

        command(&f, "close 5003", &mut next).await;
        command(&f, "close nothing-like-this", &mut next).await;
        assert!(!p.windows().iter().any(|w| w.handle == 5003));
        let _ = WindowRef { handle: 0, pid: 0 };
    }

    #[tokio::test]
    async fn find_window_by_handle_id_or_unique_title() {
        let (f, _logs) = scripted().await;
        let (p, h) = (&f.platform, &f.host);
        let first = p.windows()[0].clone();
        assert_eq!(find_window(p, h, &first.handle.to_string()), Ok(first.handle));
        let id = h.state().find_tracked_by_handle(first.handle).unwrap().id.clone();
        assert_eq!(find_window(p, h, &id), Ok(first.handle));
        assert_eq!(
            find_window(p, h, "NOTES.TXT"),
            Ok(p.windows().iter().find(|w| w.title.contains("notes")).unwrap().handle)
        );
        assert!(find_window(p, h, "123456789").unwrap_err().contains("no such window"));
        assert!(find_window(p, h, "zzz-none").unwrap_err().contains("no such window"));
        assert!(find_window(p, h, "s").unwrap_err().contains("ambiguous"));
    }

    #[test]
    fn pairing_link_is_loopback() {
        let link = PairingPayload::new(url(8797), DEFAULT_PIN).encoded_url();
        let back = PairingPayload::decode(&link).unwrap();
        assert_eq!(back.url, "ws://127.0.0.1:8797");
    }
}
