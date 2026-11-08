//! The Windows half of `--selftest`: the Win32 listing and display cases of
//! `tests/win32_*.rs`, run through the real backend and `AppState`.
//!
//! It runs on the owner's own PC, so every case keeps these rules:
//! - it opens only windows of its own and closes all of them, pass or fail
//!   (`Ctx::close_opened` after every case, and again on drop); a window is
//!   its own when it carries a title marker unique to the run (`own`), and
//!   only a console's owner shell and that shell's own children are ever
//!   ended;
//! - it never types into, moves, minimizes, focuses or closes a window it did
//!   not open: the arrange and input cases build their targets ONLY from the
//!   windows they opened (never from a listing or `AppState`, which hold the
//!   user's windows), and every backend call checks the pid still owns the
//!   handle;
//! - it focuses and types only into windows it opened, and only through
//!   `injector::execute` (which checks the foreground handle and pid before
//!   every batch and key, and the integrity level before the first input);
//!   its test wrappers (a focus thief, a counter) never send input
//!   themselves; Ctrl+C goes only to its own `ping` of 127.0.0.1; it never
//!   uses the clipboard. A case whose window loses focus to the user FAILs
//!   ("focus moved"); it never retries into whatever is in front;
//! - it never describes a window it did not open by its title (the report's
//!   `Redactor` drops any that slip through).
//!
//! - the one setting it touches, the "Start with Windows" Run value, is put
//!   back as it was; the pairing QR window it opens shows a made-up address
//!   and PIN and is closed again;
//! - the only file it writes outside its temp folder is its own probe in the
//!   logs folder (`selftest-probe-<pid>.tmp`, deleted at once) and the report.
//!
//! A case is one entry in `CASES`; the focus, typing and key cases are in
//! `win32/input.rs`.

use std::collections::{HashMap, HashSet};
use std::os::windows::process::CommandExt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, WPARAM};
use windows::Win32::System::Threading::{OpenProcess, TerminateProcess, PROCESS_TERMINATE};
use windows::Win32::UI::WindowsAndMessaging::{GetWindowThreadProcessId, IsWindow, PostMessageW, WM_CLOSE};

mod input;

use super::own;
use super::report::{exit_code, format_report, CaseResult, DisplayInfo, Header, Outcome, Redactor, EXIT_FAILED};
use crate::app_state::AppState;
use crate::platform::traits::{PlatformWindow, WindowBackend, WindowRef};
use crate::platform::win32::{effective_dpis, os_version, process_snapshot, Win32Platform};
use crate::protocol::types::ArrangeLayout;
use crate::services::arrange::{self, Target, TargetResult};
use crate::services::classify::{exe_stem, Proc, TerminalHost, CONSOLE_CLASS, WT_CLASS};
use crate::services::layout::{self, PixelRect};
use crate::services::log_paths::LogPaths;
use crate::services::multiline_policy::Shell;

/// One check. `run` gets the shared context and says what it found; anything
/// it opened through `Ctx` is closed after it returns, or panics.
pub struct Case {
    pub name: &'static str,
    pub run: fn(&mut Ctx) -> Outcome,
}

/// Every case, in the order they run.
pub const CASES: &[Case] = &[
    Case { name: "process_snapshot", run: process_snapshot_works },
    Case { name: "displays_one_primary", run: displays_one_primary },
    Case { name: "displays_work_area_inside_bounds", run: displays_work_area_inside_bounds },
    Case { name: "frames_inside_0_to_1", run: frames_inside_0_to_1 },
    Case { name: "foreground_window_owner", run: foreground_window_owner },
    Case { name: "classic_powershell_console", run: classic_powershell_console },
    Case { name: "classic_cmd_console", run: classic_cmd_console },
    Case { name: "busy_shell_reads_unknown", run: busy_shell_reads_unknown },
    Case { name: "windows_terminal", run: windows_terminal },
    Case { name: "start_with_windows_round_trip", run: start_with_windows_round_trip },
    Case { name: "pairing_qr_window", run: pairing_qr_window },
    Case { name: "arrange_own_windows", run: arrange_own_windows },
    Case { name: "arrange_restores_minimized", run: arrange_restores_minimized },
    Case { name: "minimize_and_close_own_console", run: minimize_and_close_own_console },
    Case { name: "focus_own_console", run: input::focus_own_console },
    Case { name: "type_marker_read_back", run: input::type_marker_read_back },
    Case { name: "multi_line_waits_for_return", run: input::multi_line_waits_for_return },
    Case { name: "multi_line_refused_in_cmd", run: input::multi_line_refused_in_cmd },
    Case { name: "focus_stolen_stops_typing", run: input::focus_stolen_stops_typing },
    Case { name: "quick_keys_reach_own_console", run: input::quick_keys_reach_own_console },
    Case { name: "ctrl_c_stops_ping", run: input::ctrl_c_stops_ping },
    Case { name: "elevated_target_types_nothing", run: input::elevated_target_types_nothing },
    Case { name: "build_stamp", run: build_stamp },
    Case { name: "log_dir_writable", run: log_dir_writable },
];

/// Cases the Win32 UI tests run that `--selftest` does not.
pub const EXTRA_CASES: &[Case] =
    &[Case { name: "windows_terminal_types_and_reads_back", run: input::windows_terminal_types_and_reads_back }];

/// The primary display's work area.
fn primary_work_area(ctx: &Ctx) -> Result<PixelRect, String> {
    let displays = ctx.platform.list_displays().map_err(|e| format!("list_displays: {e}"))?;
    displays.iter().find(|d| d.is_primary).map(|d| d.work_area).ok_or_else(|| "no primary display".to_string())
}

/// Arranges `own` (windows this run opened, and only those) and says what is
/// wrong: a result other than `Moved`, or a tile off the work area's edges.
fn arrange_check(ctx: &Ctx, own: &[WindowRef], layout: ArrangeLayout, restore_first: bool) -> Vec<String> {
    let work = match primary_work_area(ctx) {
        Ok(w) => w,
        Err(e) => return vec![e],
    };
    let targets: Vec<Target> = own
        .iter()
        .zip(layout::arrange(layout, own.len(), work))
        .enumerate()
        .map(|(i, (&window, visible))| Target { id: format!("own-{i}"), window, visible, restore_first })
        .collect();
    let results = arrange::execute(&ctx.platform, &targets, arrange::SETTLE);
    let mut problems: Vec<String> = results
        .iter()
        .enumerate()
        .filter(|(_, r)| **r != TargetResult::Moved)
        .map(|(i, r)| format!("{layout:?}: window {i}: {r:?} (wanted {:?})", targets[i].visible))
        .collect();
    let got: Result<Vec<PixelRect>, String> =
        own.iter().map(|&w| ctx.platform.rects(w).map(|r| r.visible).map_err(|e| format!("rects: {e}"))).collect();
    match got {
        Ok(got) => {
            let off = arrange::tiling_problems(layout, work, &got);
            if !off.is_empty() {
                problems.push(format!("{layout:?} on {work:?}: {}; got {got:?}", off.join("; ")));
            }
        }
        Err(e) => problems.push(e),
    }
    problems
}

/// Two consoles of its own, tiled side by side, then stacked.
fn arrange_own_windows(ctx: &mut Ctx) -> Outcome {
    let mut own = Vec::new();
    for tag in ["arr-a", "arr-b"] {
        match ctx.open_conhost("arrange console", tag, cmd_titled) {
            Ok(w) => own.push(w.window_ref()),
            Err(e) => return Outcome::Fail(e),
        }
    }
    let mut problems = arrange_check(ctx, &own, ArrangeLayout::Horizontal, false);
    problems.extend(arrange_check(ctx, &own, ArrangeLayout::Vertical, false));
    fail_all(problems)
}

/// One console of its own minimized first, then arranged with a second: it
/// must come back and be tiled.
fn arrange_restores_minimized(ctx: &mut Ctx) -> Outcome {
    let mut own = Vec::new();
    for tag in ["min-a", "min-b"] {
        match ctx.open_conhost("arrange console", tag, cmd_titled) {
            Ok(w) => own.push(w.window_ref()),
            Err(e) => return Outcome::Fail(e),
        }
    }
    if let Err(e) = ctx.platform.minimize(own[0]) {
        return Outcome::Fail(format!("minimize: {e}"));
    }
    let iconic = wait_until(CLOSE_WAIT, || ctx.platform.rects(own[0]).is_ok_and(|r| r.is_minimized));
    if !iconic {
        return Outcome::Fail(format!("not minimized {} s after minimize", CLOSE_WAIT.as_secs()));
    }
    let mut problems = arrange_check(ctx, &own, ArrangeLayout::Horizontal, true);
    if ctx.platform.rects(own[0]).is_ok_and(|r| r.is_minimized) {
        problems.push("still minimized after the arrange".into());
    }
    fail_all(problems)
}

/// A console of its own: minimize makes it iconic, close (`WM_CLOSE`)
/// removes it within 5 s.
fn minimize_and_close_own_console(ctx: &mut Ctx) -> Outcome {
    let w = match ctx.open_conhost("minimize console", "min-close", cmd_titled) {
        Ok(w) => w,
        Err(e) => return Outcome::Fail(e),
    };
    let own = w.window_ref();
    if let Err(e) = ctx.platform.minimize(own) {
        return Outcome::Fail(format!("minimize: {e}"));
    }
    if !wait_until(CLOSE_WAIT, || ctx.platform.rects(own).is_ok_and(|r| r.is_minimized)) {
        return Outcome::Fail(format!("not minimized {} s after minimize", CLOSE_WAIT.as_secs()));
    }
    if let Err(e) = ctx.platform.close(own) {
        return Outcome::Fail(format!("close: {e}"));
    }
    if !wait_until(CLOSE_WAIT, || !is_live(own.handle, own.pid)) {
        return Outcome::Fail(format!("still open {} s after close", CLOSE_WAIT.as_secs()));
    }
    Outcome::Pass
}

/// The tray's QR window, with a made-up address and PIN: opens, a second
/// Show reuses it, the lister leaves it out, Esc closes it.
fn pairing_qr_window(_: &mut Ctx) -> Outcome {
    let content = crate::tray::qr::pairing_qr(&[std::net::Ipv4Addr::new(192, 168, 0, 2)], 8765, "00000000");
    match crate::tray::qr_window::check_open_list_close(content) {
        Ok(()) => Outcome::Pass,
        Err(e) => Outcome::Fail(e),
    }
}

/// The tray's "Start with Windows" value: set, read back and delete under a
/// value name of this run's own (`autostart::selftest_value_name`); the
/// user's `Quip` value is only read, and must be unchanged.
fn start_with_windows_round_trip(_: &mut Ctx) -> Outcome {
    match std::env::current_exe() {
        Ok(exe) => match crate::tray::autostart::round_trip(&exe) {
            Ok(()) => Outcome::Pass,
            Err(e) => Outcome::Fail(e),
        },
        Err(e) => Outcome::Fail(format!("cannot find Quip.exe: {e}")),
    }
}

/// `CREATE_NEW_CONSOLE`: without it the `cmd /c start` helper shares the
/// console Quip was started from.
const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
const OPEN_WAIT: Duration = Duration::from_secs(15);
const WT_OPEN_WAIT: Duration = Duration::from_secs(20);
const SHELL_WAIT: Duration = Duration::from_secs(15);
const CLOSE_WAIT: Duration = Duration::from_secs(5);
const POLL: Duration = Duration::from_millis(200);

/// Something a case started, known by the title marker it set.
struct Opened {
    what: &'static str,
    marker: String,
    /// The window class the marker is looked for in.
    class: &'static str,
    /// (handle, owner pid) once its window was found.
    window: Option<(u64, u32)>,
    /// A classic console: its owner shell and that shell's own children may
    /// be ended. Not for Windows Terminal, whose process can hold the user's
    /// own windows: its window only gets `WM_CLOSE`.
    may_end: bool,
}

pub struct Ctx {
    platform: Win32Platform,
    redactor: Redactor,
    opened: Vec<Opened>,
    markers: u32,
    /// The run's own temp folder (the input cases' result files), made on
    /// first use and removed at the end.
    dir: Option<std::path::PathBuf>,
    /// `Quip.exe`, for the integrity probe.
    probe_exe: std::path::PathBuf,
    /// The current case's notes (`CaseResult::notes`).
    notes: Vec<String>,
}

impl Ctx {
    /// The real listing. Every title in it counts as foreign to the report
    /// until a case claims the window as its own.
    fn list(&mut self) -> Result<Vec<PlatformWindow>, String> {
        let windows = self.platform.list_windows().map_err(|e| format!("list_windows: {e}"))?;
        for w in &windows {
            self.redactor.foreign_title(&w.title);
        }
        Ok(windows)
    }

    fn handles(&mut self) -> Result<HashSet<u64>, String> {
        Ok(self.list()?.into_iter().map(|w| w.handle).collect())
    }

    /// A title marker no other window of this run, or any run of another
    /// process, carries.
    fn new_marker(&mut self, tag: &str) -> String {
        self.markers += 1;
        own::marker(std::process::id(), self.markers, tag)
    }

    /// Records what a case is about to start, before it starts, so cleanup
    /// looks for its marker even when the window is never identified.
    fn expect(&mut self, what: &'static str, marker: &str, class: &'static str, may_end: bool) -> usize {
        self.redactor.own_title(marker);
        self.opened.push(Opened { what, marker: marker.to_string(), class, window: None, may_end });
        self.opened.len() - 1
    }

    /// Polls until a window not in `before` matches `pick`.
    fn wait_new(
        &mut self,
        before: &HashSet<u64>,
        timeout: Duration,
        pick: impl Fn(&PlatformWindow) -> bool,
    ) -> Option<PlatformWindow> {
        let start = Instant::now();
        while start.elapsed() < timeout {
            if let Ok(windows) = self.list() {
                if let Some(w) = windows.into_iter().find(|w| !before.contains(&w.handle) && pick(w)) {
                    return Some(w);
                }
            }
            sleep(POLL);
        }
        None
    }

    /// Polls until the listed window `handle` satisfies `ok`; the last
    /// listing of it either way.
    fn wait_listed(
        &mut self,
        handle: u64,
        timeout: Duration,
        ok: impl Fn(&PlatformWindow) -> bool,
    ) -> Option<PlatformWindow> {
        let start = Instant::now();
        let mut last = None;
        while start.elapsed() < timeout {
            last = self.list().ok().and_then(|ws| ws.into_iter().find(|w| w.handle == handle));
            if last.as_ref().is_some_and(&ok) {
                break;
            }
            sleep(POLL);
        }
        last
    }

    fn claim(&mut self, index: usize, w: &PlatformWindow) {
        if let Some(o) = self.opened.get_mut(index) {
            o.window = Some((w.handle, w.pid));
        }
        self.redactor.own_title(&w.title);
    }

    /// `cmd /c start "" conhost.exe <args>`: a classic console with its own
    /// window, even under CI's redirected stdio (spec 10.5). `args(marker)`
    /// must make the shell set the console title to `marker`; the window is
    /// the new console window carrying it, so a console the user has open is
    /// never taken for it. (The window's owner is the shell, not conhost.)
    fn open_conhost(
        &mut self,
        what: &'static str,
        tag: &str,
        args: impl Fn(&str) -> String,
    ) -> Result<PlatformWindow, String> {
        self.open_conhost_marked(what, tag, args).map(|(w, _)| w)
    }

    /// `open_conhost`, also giving the marker it set.
    fn open_conhost_marked(
        &mut self,
        what: &'static str,
        tag: &str,
        args: impl Fn(&str) -> String,
    ) -> Result<(PlatformWindow, String), String> {
        let marker = self.new_marker(tag);
        let args = args(&marker);
        let before = self.handles()?;
        let index = self.expect(what, &marker, CONSOLE_CLASS, true);
        Command::new("cmd.exe")
            .creation_flags(CREATE_NEW_CONSOLE)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .raw_arg(format!(r#"/c start "" conhost.exe {args}"#))
            .status()
            .map_err(|e| format!("cannot run cmd.exe: {e}"))?;
        let found =
            self.wait_new(&before, OPEN_WAIT, |w| w.class_name == CONSOLE_CLASS && own::has_marker(&w.title, &marker));
        match found {
            Some(w) => {
                self.claim(index, &w);
                Ok((w, marker))
            }
            None => Err(format!(
                "no new console window titled {marker} in {} s\nevery top-level {CONSOLE_CLASS} window:\n{}console processes:\n{}",
                OPEN_WAIT.as_secs(),
                self.platform.explain_class(CONSOLE_CLASS),
                console_processes(),
            )),
        }
    }

    /// Listed windows of `class` carrying `marker`, as (handle, owner pid).
    fn marked(&mut self, class: &str, marker: &str) -> Vec<(u64, u32)> {
        self.list()
            .unwrap_or_default()
            .into_iter()
            .filter(|w| w.class_name == class && own::has_marker(&w.title, marker))
            .map(|w| (w.handle, w.pid))
            .collect()
    }

    /// Closes everything the current case opened: every window carrying its
    /// marker (found or not) gets `WM_CLOSE`; a console still open after that
    /// has its owner shell and that shell's own children ended. Returns what
    /// could not be closed: a window with the marker still listed, or one of
    /// its processes still running.
    fn close_opened(&mut self) -> Vec<String> {
        let mut problems = Vec::new();
        for o in std::mem::take(&mut self.opened) {
            let mut windows: Vec<(u64, u32)> = o.window.into_iter().collect();
            for w in self.marked(o.class, &o.marker) {
                if !windows.contains(&w) {
                    windows.push(w);
                }
            }
            windows.retain(|&(h, p)| is_live(h, p));
            // Taken while each window is known to be ours (its owner checked).
            let procs = process_snapshot().unwrap_or_default();
            let targets: Vec<Proc> = if o.may_end {
                windows.iter().flat_map(|&(_, pid)| own::cleanup_targets(pid, &procs)).collect()
            } else {
                Vec::new()
            };
            for &(h, _) in &windows {
                post_close(h);
            }
            // `WM_CLOSE` ends a console's processes too; whatever of its own
            // tree is left after that is ended.
            let _ = wait_until(CLOSE_WAIT, || windows.iter().all(|&(h, p)| !is_live(h, p)));
            if o.may_end {
                let gone = wait_until(CLOSE_WAIT, || {
                    let now = process_snapshot().unwrap_or_default();
                    let left = own::still_running(&targets, &now);
                    end(&left);
                    left.is_empty() && windows.iter().all(|&(h, p)| !is_live(h, p))
                });
                if !gone {
                    problems.push(format!("the {} it opened is still running", o.what));
                }
            }
            if !self.marked(o.class, &o.marker).is_empty() {
                problems.push(format!("a {} window titled {} is still open", o.what, o.marker));
            }
        }
        problems
    }
}

impl Ctx {
    fn new(platform: Win32Platform, redactor: Redactor, probe_exe: std::path::PathBuf) -> Ctx {
        Ctx { platform, redactor, opened: Vec::new(), markers: 0, dir: None, probe_exe, notes: Vec::new() }
    }

    fn remove_dir(&mut self) {
        if let Some(d) = self.dir.take() {
            let _ = std::fs::remove_dir_all(d);
        }
    }
}

impl Drop for Ctx {
    fn drop(&mut self) {
        let _ = self.close_opened();
        self.remove_dir();
    }
}

/// Runs the named cases (from `CASES` or `EXTRA_CASES`) the way `--selftest`
/// does, for the Win32 UI tests. `probe_exe` is `Quip.exe`. An unknown name
/// is an `Err`.
pub fn run_named(names: &[&str], probe_exe: std::path::PathBuf) -> Result<Vec<CaseResult>, String> {
    let platform = Win32Platform::new().map_err(|e| e.to_string())?;
    let all: Vec<&Case> = CASES.iter().chain(EXTRA_CASES).collect();
    let mut picked = Vec::new();
    for n in names {
        let c = all.iter().find(|c| c.name == *n).ok_or_else(|| format!("no case {n}"))?;
        picked.push(Case { name: c.name, run: c.run });
    }
    let mut ctx = Ctx::new(platform, Redactor::new(), probe_exe);
    let results = run_cases(&mut ctx, &picked);
    ctx.remove_dir();
    Ok(results)
}

fn hwnd(handle: u64) -> HWND {
    HWND(handle as usize as *mut std::ffi::c_void)
}

fn owner_of(handle: u64) -> u32 {
    let mut pid = 0u32;
    // SAFETY: a writable out pointer; any handle value is accepted.
    unsafe { GetWindowThreadProcessId(hwnd(handle), Some(&mut pid)) };
    pid
}

/// The window still exists and `pid` still owns it (HWND values are reused).
fn is_live(handle: u64, pid: u32) -> bool {
    // SAFETY: any handle value is accepted.
    unsafe { IsWindow(hwnd(handle)) }.as_bool() && owner_of(handle) == pid
}

fn post_close(handle: u64) {
    // SAFETY: posting to a stale handle fails harmlessly.
    let _ = unsafe { PostMessageW(hwnd(handle), WM_CLOSE, WPARAM(0), LPARAM(0)) };
}

fn wait_until(timeout: Duration, mut done: impl FnMut() -> bool) -> bool {
    let start = Instant::now();
    loop {
        if done() {
            return true;
        }
        if start.elapsed() >= timeout {
            return false;
        }
        sleep(POLL);
    }
}

/// Ends `pids`, which `own::still_running` picked from a console's own tree.
fn end(pids: &[u32]) {
    for &pid in pids {
        // SAFETY: plain arguments; the handle is closed right after.
        if let Ok(h) = unsafe { OpenProcess(PROCESS_TERMINATE, false, pid) } {
            // SAFETY: a live process handle opened with PROCESS_TERMINATE,
            // closed exactly once here.
            unsafe {
                let _ = TerminateProcess(h, 1);
                let _ = CloseHandle(h);
            }
        }
    }
}

/// The processes under `root`, one per line, for a failure detail. Exe file
/// names only.
fn process_tree(root: u32) -> String {
    let procs = process_snapshot().unwrap_or_default();
    own::tree(root, &procs).into_iter().map(|(pid, exe)| format!("{pid} {exe}\n")).collect()
}

/// Every conhost / OpenConsole / shell process with its parent, for a
/// failure detail.
fn console_processes() -> String {
    const NAMES: [&str; 5] = ["conhost", "openconsole", "cmd", "powershell", "pwsh"];
    process_snapshot()
        .unwrap_or_default()
        .iter()
        .filter(|p| NAMES.contains(&exe_stem(&p.exe).as_str()))
        .map(|p| format!("{} parent={} {}\n", p.pid, p.parent, p.exe))
        .collect()
}

fn fail_all(problems: Vec<String>) -> Outcome {
    if problems.is_empty() {
        Outcome::Pass
    } else {
        Outcome::Fail(problems.join("\n"))
    }
}

/// This exe names its commit (an unstamped build cannot be traced). No SKIP.
fn build_stamp(ctx: &mut Ctx) -> Outcome {
    match super::check_build_stamp(crate::build_info::BUILD) {
        Ok(sha) => {
            ctx.notes.push(format!("commit {sha}"));
            Outcome::Pass
        }
        Err(e) => Outcome::Fail(e),
    }
}

/// The logs folder takes a file of its own (made and deleted again); a host
/// that cannot write there logs nothing. No SKIP.
fn log_dir_writable(_: &mut Ctx) -> Outcome {
    let dir = LogPaths::default_dir(&|k| std::env::var(k).ok());
    match super::check_log_dir_writable(&dir, std::process::id()) {
        Ok(()) => Outcome::Pass,
        Err(e) => Outcome::Fail(e),
    }
}

fn process_snapshot_works(_: &mut Ctx) -> Outcome {
    let procs = match process_snapshot() {
        Ok(p) => p,
        Err(e) => return Outcome::Fail(format!("process snapshot: {e}")),
    };
    let me = std::process::id();
    match procs.iter().find(|p| p.pid == me) {
        Some(p) if !p.exe.is_empty() => Outcome::Pass,
        Some(_) => Outcome::Fail("its own process has no exe name".into()),
        None => Outcome::Fail(format!("{} processes, but not its own (pid {me})", procs.len())),
    }
}

fn displays_one_primary(ctx: &mut Ctx) -> Outcome {
    let displays = match ctx.platform.list_displays() {
        Ok(d) => d,
        Err(e) => return Outcome::Fail(format!("list_displays: {e}")),
    };
    let primaries: Vec<_> = displays.iter().filter(|d| d.is_primary).collect();
    match primaries.as_slice() {
        [p] if (p.bounds.x, p.bounds.y) == (0, 0) => Outcome::Pass,
        [p] => Outcome::Fail(format!("the primary is not at the origin: {p:?}")),
        _ => Outcome::Fail(format!("{} primaries among {displays:?}", primaries.len())),
    }
}

fn displays_work_area_inside_bounds(ctx: &mut Ctx) -> Outcome {
    let displays = match ctx.platform.list_displays() {
        Ok(d) => d,
        Err(e) => return Outcome::Fail(format!("list_displays: {e}")),
    };
    let problems = displays
        .iter()
        .filter(|d| {
            let (b, w) = (d.bounds, d.work_area);
            let inside = w.x >= b.x && w.y >= b.y && w.right() <= b.right() && w.bottom() <= b.bottom();
            !(b.width > 0 && b.height > 0 && w.width > 0 && w.height > 0 && inside)
        })
        .map(|d| format!("work area not inside the bounds: {d:?}"))
        .collect();
    fail_all(problems)
}

/// Every window inside a display gets a frame in 0..1 from `AppState`, the
/// same path the phone's layout comes from. It opens a console of its own so
/// the check never passes on an empty desktop.
fn frames_inside_0_to_1(ctx: &mut Ctx) -> Outcome {
    let own = match ctx.open_conhost("frames console", "frames", cmd_titled) {
        Ok(w) => w,
        Err(e) => return Outcome::Fail(e),
    };
    let displays = match ctx.platform.list_displays() {
        Ok(d) => d,
        Err(e) => return Outcome::Fail(format!("list_displays: {e}")),
    };
    let windows = match ctx.list() {
        Ok(w) => w,
        Err(e) => return Outcome::Fail(e),
    };
    let fg = ctx.platform.foreground_window().ok().flatten();
    let mut state = AppState::new(HashMap::new(), true);
    state.update(windows, displays.clone(), fg);
    let mut problems = Vec::new();
    let mut own_seen = false;
    for t in state.windows() {
        let is_own = t.platform.handle == own.handle;
        own_seen |= is_own;
        // Described by class and app, never by title (it may not be ours).
        let who = format!("a {} window of {}", t.platform.class_name, t.platform.app);
        if is_own && t.display_id.is_none() {
            problems.push(format!("its own console is on no display: {:?}", t.platform.visible));
        }
        let v = t.platform.visible;
        let inside = displays.iter().any(|d| {
            v.x >= d.bounds.x && v.y >= d.bounds.y && v.right() <= d.bounds.right() && v.bottom() <= d.bounds.bottom()
        });
        if !inside {
            continue;
        }
        let f = t.frame;
        for (what, x) in [("x", f.x), ("y", f.y), ("width", f.width), ("height", f.height)] {
            if !(0.0..=1.0).contains(&x) {
                problems.push(format!("{what} of {who} is {x}: {f:?}"));
            }
        }
        if t.display_id.is_none() {
            problems.push(format!("{who} is inside a display but has no display id"));
        }
    }
    if !own_seen {
        problems.push("its own console is not in AppState".into());
    }
    fail_all(problems)
}

fn foreground_window_owner(ctx: &mut Ctx) -> Outcome {
    match ctx.platform.foreground_window() {
        Err(e) => Outcome::Fail(format!("foreground_window: {e}")),
        Ok(None) => Outcome::Skip("nothing is in the foreground".into()),
        Ok(Some(w)) => {
            let owner = owner_of(w.handle);
            if owner == w.pid {
                Outcome::Pass
            } else {
                Outcome::Fail(format!("reported pid {} but the window's owner is {owner}", w.pid))
            }
        }
    }
}

/// cmd sets no title of its own and spec 5.1 leaves untitled windows out;
/// the `title` builtin names it without adding a child process.
fn cmd_titled(marker: &str) -> String {
    format!("cmd.exe /K title {marker}")
}

/// PowerShell titling its console, then running `then` (if any) in it.
fn powershell_titled(marker: &str, then: &str) -> String {
    format!(r#"powershell.exe -NoLogo -NoExit -Command "$Host.UI.RawUI.WindowTitle='{marker}'{then}""#)
}

/// Opens a classic console running `args(marker)` and checks how it is
/// listed.
fn console_case(
    ctx: &mut Ctx,
    what: &'static str,
    tag: &str,
    args: impl Fn(&str) -> String,
    shell: Shell,
    app: &str,
) -> Outcome {
    let w = match ctx.open_conhost(what, tag, args) {
        Ok(w) => w,
        Err(e) => return Outcome::Fail(e),
    };
    let got = ctx.wait_listed(w.handle, SHELL_WAIT, |w| w.shell == Some(shell));
    let tree = process_tree(w.pid);
    let Some(got) = got else {
        return Outcome::Fail(format!(
            "its console left the listing\n{tree}{}",
            ctx.platform.explain_class(CONSOLE_CLASS)
        ));
    };
    ctx.redactor.own_title(&got.title);
    let mut problems = Vec::new();
    if got.terminal != Some(TerminalHost::Console) {
        problems.push(format!("terminal is {:?}, not Console", got.terminal));
    }
    if got.shell != Some(shell) {
        problems.push(format!("shell is {:?}, not {shell:?}; processes under the owner:\n{tree}", got.shell));
    }
    if got.app != app {
        problems.push(format!("app is {:?}, not {app:?}", got.app));
    }
    if got.title.is_empty() {
        problems.push("listed without a title".into());
    }
    match ctx.platform.current_shell(got.window_ref()) {
        Ok(Some(s)) if s == shell => {}
        other => problems.push(format!("current_shell says {other:?}, not {shell:?}")),
    }
    fail_all(problems)
}

fn classic_powershell_console(ctx: &mut Ctx) -> Outcome {
    console_case(ctx, "PowerShell console", "ps", |m| powershell_titled(m, ""), Shell::PowerShell, "PowerShell")
}

fn classic_cmd_console(ctx: &mut Ctx) -> Outcome {
    console_case(ctx, "cmd console", "cmd", cmd_titled, Shell::Cmd, "Command Prompt")
}

/// ping stands in for python / ssh / node: any non-shell child of the shell
/// is a program that would get the phone's keys. The title is set before
/// ping starts.
fn busy_shell_reads_unknown(ctx: &mut Ctx) -> Outcome {
    console_case(
        ctx,
        "busy PowerShell console",
        "busy",
        |m| powershell_titled(m, "; ping -n 120 127.0.0.1"),
        Shell::Unknown,
        "Console",
    )
}

fn on_path(exe: &str) -> bool {
    Command::new("where.exe").arg(exe).stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success())
}

/// A new Windows Terminal window, found by the title its PowerShell tab sets
/// (the window shows the active tab's title), so a window the user opens
/// meanwhile is never taken for it.
fn windows_terminal(ctx: &mut Ctx) -> Outcome {
    if !on_path("wt.exe") {
        return Outcome::Skip("wt.exe is not installed".into());
    }
    let before = match ctx.handles() {
        Ok(h) => h,
        Err(e) => return Outcome::Fail(e),
    };
    let marker = ctx.new_marker("wt");
    let set_title = format!("$Host.UI.RawUI.WindowTitle='{marker}'");
    let index = ctx.expect("Windows Terminal", &marker, WT_CLASS, false);
    let launched = Command::new("wt.exe")
        .args(["-w", "new", "powershell.exe", "-NoLogo", "-NoExit", "-Command", &set_title])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if let Err(e) = launched {
        return Outcome::Fail(format!("cannot run wt.exe: {e}"));
    }
    let Some(w) =
        ctx.wait_new(&before, WT_OPEN_WAIT, |w| w.class_name == WT_CLASS && own::has_marker(&w.title, &marker))
    else {
        let others =
            ctx.list().map(|ws| ws.iter().filter(|w| w.class_name == WT_CLASS && !before.contains(&w.handle)).count());
        return Outcome::Fail(format!(
            "no new Windows Terminal window titled {marker} in {} s ({} other new ones, left alone)",
            WT_OPEN_WAIT.as_secs(),
            others.map(|n| n.to_string()).unwrap_or_else(|e| e),
        ));
    };
    ctx.claim(index, &w);
    let got = ctx.wait_listed(w.handle, SHELL_WAIT, |w| w.shell == Some(Shell::PowerShell));
    let tree = process_tree(w.pid);
    let Some(got) = got else { return Outcome::Fail("its Windows Terminal window left the listing".into()) };
    let mut problems = Vec::new();
    if got.terminal != Some(TerminalHost::WindowsTerminal) {
        problems.push(format!("terminal is {:?}, not WindowsTerminal", got.terminal));
    }
    if got.app != "Windows Terminal" {
        problems.push(format!("app is {:?}, not \"Windows Terminal\"", got.app));
    }
    if got.shell != Some(Shell::PowerShell) {
        problems
            .push(format!("shell is {:?}, not PowerShell; processes under WindowsTerminal.exe:\n{tree}", got.shell));
    }
    match ctx.platform.current_shell(got.window_ref()) {
        Ok(Some(Shell::PowerShell)) => {}
        other => problems.push(format!("current_shell says {other:?}, not PowerShell")),
    }
    fail_all(problems)
}

fn header(platform: &Win32Platform, unix_seconds: f64) -> Header {
    let dpis = effective_dpis();
    let displays = platform
        .list_displays()
        .unwrap_or_default()
        .into_iter()
        .map(|d| DisplayInfo {
            dpi: dpis.iter().find(|(dev, _)| *dev == d.device_name).map(|(_, dpi)| *dpi),
            name: d.name,
            is_primary: d.is_primary,
            bounds: d.bounds,
            work_area: d.work_area,
        })
        .collect();
    Header { unix_seconds, build: crate::build_info::BUILD.to_string(), windows_version: os_version(), displays }
}

/// Runs `cases` in order. A panicking case fails; whatever a case opened is
/// closed before the next one starts, and a window it could not close fails
/// it too.
fn run_cases(ctx: &mut Ctx, cases: &[Case]) -> Vec<CaseResult> {
    let mut results = Vec::with_capacity(cases.len());
    for case in cases {
        ctx.notes.clear();
        let outcome = catch_unwind(AssertUnwindSafe(|| (case.run)(ctx)))
            .unwrap_or_else(|_| Outcome::Fail("the case panicked".into()));
        let left = ctx.close_opened();
        let outcome = match (outcome, left.is_empty()) {
            (o, true) => o,
            (Outcome::Fail(d), false) => Outcome::Fail(format!("{d}\n{}", left.join("\n"))),
            (_, false) => Outcome::Fail(left.join("\n")),
        };
        eprintln!("{} {}", outcome.label(), case.name);
        results.push(CaseResult { name: case.name.to_string(), outcome, notes: std::mem::take(&mut ctx.notes) });
    }
    results
}

/// `Quip.exe --selftest`: runs every case, prints the report, writes it to
/// the log folder. The exit code is `report::exit_code`.
pub fn run() -> i32 {
    let env = |k: &str| std::env::var(k).ok();
    let started = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    let platform = match Win32Platform::new() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Quip selftest: {e}");
            return EXIT_FAILED;
        }
    };
    let redactor = Redactor::from_env(&env, hostname::get().ok().and_then(|h| h.into_string().ok()));
    let header = header(&platform, started);
    let probe_exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Quip selftest: cannot find Quip.exe: {e}");
            return EXIT_FAILED;
        }
    };
    let mut ctx = Ctx::new(platform, redactor, probe_exe);
    let results = run_cases(&mut ctx, CASES);
    ctx.remove_dir();
    let text = format_report(&header, &results, &ctx.redactor);
    print!("{text}");
    let dir = LogPaths::default_dir(&env);
    match super::write_report(&dir, started, &text) {
        Ok(path) => {
            eprintln!("selftest report: {}", path.display());
            exit_code(&results)
        }
        Err(e) => {
            eprintln!("cannot write the selftest report in {}: {e}", dir.display());
            EXIT_FAILED
        }
    }
}
