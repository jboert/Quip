//! The Windows half of `--selftest`: the Win32 listing and display cases of
//! `tests/win32_*.rs`, run through the real backend and `AppState`.
//!
//! It runs on the owner's own PC, so every case keeps these rules:
//! - it opens only windows of its own and closes all of them, pass or fail
//!   (`Ctx::close_opened` after every case, and again on drop);
//! - it never types into, moves, focuses or closes a window it did not open;
//!   the consoles it opens come to the front by themselves, nothing more;
//! - it never describes a window it did not open by its title (the report's
//!   `Redactor` drops any that slip through).
//!
//! A case is one entry in `CASES`; arrange and typing cases are added there.

use std::collections::{HashMap, HashSet};
use std::os::windows::process::CommandExt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, WPARAM};
use windows::Win32::System::Threading::{OpenProcess, TerminateProcess, PROCESS_TERMINATE};
use windows::Win32::UI::WindowsAndMessaging::{GetWindowThreadProcessId, IsWindow, PostMessageW, WM_CLOSE};

use super::report::{exit_code, format_report, CaseResult, DisplayInfo, Header, Outcome, Redactor, EXIT_FAILED};
use crate::app_state::AppState;
use crate::platform::traits::{PlatformWindow, WindowBackend};
use crate::platform::win32::{effective_dpis, os_version, process_snapshot, Win32Platform};
use crate::services::classify::{exe_stem, Proc, TerminalHost, CONSOLE_CLASS, WT_CLASS};
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
];

/// `CREATE_NEW_CONSOLE`: without it the `cmd /c start` helper shares the
/// console Quip was started from.
const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
const OPEN_WAIT: Duration = Duration::from_secs(15);
const WT_OPEN_WAIT: Duration = Duration::from_secs(20);
const SHELL_WAIT: Duration = Duration::from_secs(15);
const CLOSE_WAIT: Duration = Duration::from_secs(5);
const POLL: Duration = Duration::from_millis(200);

/// Processes the selftest starts (and so may end, under a console it opened).
const OWN_STEMS: [&str; 4] = ["conhost", "cmd", "powershell", "ping"];

const CMD_TITLE: &str = "Quip-selftest-cmd";
const FRAMES_TITLE: &str = "Quip-selftest-frames";
const WT_TITLE: &str = "Quip-selftest-wt";

/// Something a case started.
struct Opened {
    what: &'static str,
    /// (handle, owner pid) once its window was found.
    window: Option<(u64, u32)>,
    /// The process the selftest started (conhost.exe for a classic console):
    /// it and its descendants may be ended. `None` for Windows Terminal,
    /// whose process can hold the user's own windows: only its window gets
    /// `WM_CLOSE`.
    root: Option<u32>,
}

pub struct Ctx {
    platform: Win32Platform,
    redactor: Redactor,
    opened: Vec<Opened>,
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

    /// Polls until a window not in `before` matches `pick`.
    fn wait_new(
        &mut self,
        before: &HashSet<u64>,
        timeout: Duration,
        pick: impl Fn(&PlatformWindow, &[Proc]) -> bool,
    ) -> Option<PlatformWindow> {
        let start = Instant::now();
        while start.elapsed() < timeout {
            let procs = process_snapshot().unwrap_or_default();
            if let Ok(windows) = self.list() {
                if let Some(w) = windows.into_iter().find(|w| !before.contains(&w.handle) && pick(w, &procs)) {
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
    /// window, even under CI's redirected stdio (spec 10.5). Its conhost.exe
    /// is found as the child of that cmd, and its window as the new console
    /// window owned by that conhost or a process under it, so a console the
    /// user opens meanwhile is never taken for it.
    fn open_conhost(&mut self, what: &'static str, args: &str) -> Result<PlatformWindow, String> {
        let before = self.handles()?;
        let mut helper = Command::new("cmd.exe")
            .creation_flags(CREATE_NEW_CONSOLE)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .raw_arg(format!(r#"/c start "" conhost.exe {args}"#))
            .spawn()
            .map_err(|e| format!("cannot run cmd.exe: {e}"))?;
        let helper_pid = helper.id();
        let _ = helper.wait();
        let procs = process_snapshot().map_err(|e| format!("process snapshot: {e}"))?;
        let root = procs
            .iter()
            .find(|p| p.parent == helper_pid && exe_stem(&p.exe) == "conhost")
            .map(|p| p.pid)
            .ok_or_else(|| format!("`cmd /c start conhost.exe {args}` started no conhost.exe"))?;
        self.opened.push(Opened { what, window: None, root: Some(root) });
        let index = self.opened.len() - 1;
        let found = self.wait_new(&before, OPEN_WAIT, |w, procs| {
            w.class_name == CONSOLE_CLASS && descends_from(w.pid, root, procs)
        });
        match found {
            Some(w) => {
                self.claim(index, &w);
                Ok(w)
            }
            None => Err(format!(
                "no console window from its conhost.exe in {} s\nevery top-level {CONSOLE_CLASS} window:\n{}processes under its conhost:\n{}",
                OPEN_WAIT.as_secs(),
                self.platform.explain_class(CONSOLE_CLASS),
                process_tree(root),
            )),
        }
    }

    /// Closes everything the current case opened: `WM_CLOSE` to its window,
    /// then, for a console, ends whatever is left of its own process tree.
    /// Returns what could not be closed.
    fn close_opened(&mut self) -> Vec<String> {
        let mut problems = Vec::new();
        for o in std::mem::take(&mut self.opened) {
            if let Some((handle, pid)) = o.window {
                post_close(handle);
                let closed = wait_until(CLOSE_WAIT, || !is_live(handle, pid));
                if !closed && o.root.is_none() {
                    problems.push(format!("the {} window it opened did not close", o.what));
                }
            }
            if let Some(root) = o.root {
                end_tree(root);
                let gone = wait_until(CLOSE_WAIT, || {
                    o.window.is_none_or(|(h, p)| !is_live(h, p)) && own_tree(root).is_empty()
                });
                if !gone {
                    problems.push(format!("the {} it opened is still running", o.what));
                }
            }
        }
        problems
    }
}

impl Drop for Ctx {
    fn drop(&mut self) {
        let _ = self.close_opened();
    }
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

fn descends_from(pid: u32, root: u32, procs: &[Proc]) -> bool {
    let mut cur = pid;
    for _ in 0..64 {
        if cur == root {
            return true;
        }
        match procs.iter().find(|p| p.pid == cur) {
            Some(p) if p.parent != cur && p.parent != 0 => cur = p.parent,
            _ => return false,
        }
    }
    false
}

/// `root` and everything under it, as (pid, exe).
fn tree(root: u32, procs: &[Proc]) -> Vec<(u32, String)> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let mut stack = vec![root];
    while let Some(pid) = stack.pop() {
        if !seen.insert(pid) {
            continue;
        }
        if let Some(p) = procs.iter().find(|p| p.pid == pid) {
            out.push((p.pid, p.exe.clone()));
        }
        stack.extend(procs.iter().filter(|c| c.parent == pid && c.pid != pid).map(|c| c.pid));
    }
    out
}

/// What is still running of a tree the selftest started, limited to the
/// programs it starts itself.
fn own_tree(root: u32) -> Vec<u32> {
    let procs = process_snapshot().unwrap_or_default();
    tree(root, &procs)
        .into_iter()
        .filter(|(_, exe)| OWN_STEMS.contains(&exe_stem(exe).as_str()))
        .map(|(p, _)| p)
        .collect()
}

fn end_tree(root: u32) {
    for pid in own_tree(root) {
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
    tree(root, &procs).into_iter().map(|(pid, exe)| format!("{pid} {exe}\n")).collect()
}

fn fail_all(problems: Vec<String>) -> Outcome {
    if problems.is_empty() {
        Outcome::Pass
    } else {
        Outcome::Fail(problems.join("\n"))
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
    let own = match ctx.open_conhost("frames console", &format!("cmd.exe /K title {FRAMES_TITLE}")) {
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

/// Opens a classic console running `args` and checks how it is listed.
fn console_case(ctx: &mut Ctx, what: &'static str, args: &str, shell: Shell, app: &str) -> Outcome {
    let w = match ctx.open_conhost(what, args) {
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
    console_case(ctx, "PowerShell console", "powershell.exe -NoLogo -NoExit", Shell::PowerShell, "PowerShell")
}

/// cmd sets no title of its own and spec 5.1 leaves untitled windows out;
/// the `title` builtin names it without adding a child process.
fn classic_cmd_console(ctx: &mut Ctx) -> Outcome {
    console_case(ctx, "cmd console", &format!("cmd.exe /K title {CMD_TITLE}"), Shell::Cmd, "Command Prompt")
}

/// ping stands in for python / ssh / node: any non-shell child of the shell
/// is a program that would get the phone's keys.
fn busy_shell_reads_unknown(ctx: &mut Ctx) -> Outcome {
    console_case(
        ctx,
        "busy PowerShell console",
        "powershell.exe -NoLogo -NoExit -Command ping -n 120 127.0.0.1",
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
    let set_title = format!("$Host.UI.RawUI.WindowTitle='{WT_TITLE}'");
    let launched = Command::new("wt.exe")
        .args(["-w", "new", "powershell.exe", "-NoLogo", "-NoExit", "-Command", &set_title])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if let Err(e) = launched {
        return Outcome::Fail(format!("cannot run wt.exe: {e}"));
    }
    ctx.opened.push(Opened { what: "Windows Terminal", window: None, root: None });
    let index = ctx.opened.len() - 1;
    let Some(w) = ctx.wait_new(&before, WT_OPEN_WAIT, |w, _| w.class_name == WT_CLASS && w.title == WT_TITLE) else {
        let others =
            ctx.list().map(|ws| ws.iter().filter(|w| w.class_name == WT_CLASS && !before.contains(&w.handle)).count());
        return Outcome::Fail(format!(
            "no new Windows Terminal window titled {WT_TITLE} in {} s ({} other new ones, left alone)",
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
    Header {
        unix_seconds,
        quip_version: env!("CARGO_PKG_VERSION").to_string(),
        git_sha: option_env!("QUIP_GIT_SHA").map(str::to_string),
        windows_version: os_version(),
        displays,
    }
}

/// Runs `cases` in order. A panicking case fails; whatever a case opened is
/// closed before the next one starts, and a window it could not close fails
/// it too.
fn run_cases(ctx: &mut Ctx, cases: &[Case]) -> Vec<CaseResult> {
    let mut results = Vec::with_capacity(cases.len());
    for case in cases {
        let outcome = catch_unwind(AssertUnwindSafe(|| (case.run)(ctx)))
            .unwrap_or_else(|_| Outcome::Fail("the case panicked".into()));
        let left = ctx.close_opened();
        let outcome = match (outcome, left.is_empty()) {
            (o, true) => o,
            (Outcome::Fail(d), false) => Outcome::Fail(format!("{d}\n{}", left.join("\n"))),
            (_, false) => Outcome::Fail(left.join("\n")),
        };
        eprintln!("{} {}", outcome.label(), case.name);
        results.push(CaseResult { name: case.name.to_string(), outcome });
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
    let mut ctx = Ctx { platform, redactor, opened: Vec::new() };
    let results = run_cases(&mut ctx, CASES);
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
