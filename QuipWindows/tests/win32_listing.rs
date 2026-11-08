//! Spec 10.5, listing: the real Win32 backend against real windows. They
//! open consoles, Windows Terminal and Notepad, so they only run with
//! `QUIP_WIN_UI=1` (Windows CI sets it; run them one at a time with
//! `--test-threads=1`, they share the desktop).
//!
//! Every window a test opens is found by a title marker it sets itself
//! (`selftest::own::marker`), as `Quip.exe --selftest` does, so a window the
//! user has open is never taken for it, and never closed.
#![cfg(windows)]

use std::collections::HashSet;
use std::os::windows::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread::sleep;
use std::time::{Duration, Instant};

use quip_windows::platform::traits::{PlatformWindow, WindowBackend, WindowRef};
use quip_windows::platform::win32::{process_snapshot, terminate_if_same, Win32Platform};
use quip_windows::selftest::own::{has_marker, marker};
use quip_windows::services::classify::{exe_stem, TerminalHost, CONSOLE_CLASS, WT_CLASS};
use quip_windows::services::layout::PixelRect;
use quip_windows::services::multiline_policy::Shell;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{BOOL, HWND, LPARAM, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_CLOAK};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DestroyWindow, GetWindowRect, PostMessageW, ShowWindow, SW_MINIMIZE, WINDOW_EX_STYLE,
    WINDOW_STYLE, WM_CLOSE, WS_CAPTION, WS_EX_TOOLWINDOW, WS_OVERLAPPEDWINDOW, WS_POPUP, WS_VISIBLE,
};

/// `CREATE_NEW_CONSOLE`: without it the `cmd /c start` helper shares the test
/// runner's console.
const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;

fn ui_enabled() -> bool {
    if std::env::var("QUIP_WIN_UI").as_deref() == Ok("1") {
        return true;
    }
    eprintln!("skipped: set QUIP_WIN_UI=1 to run the Win32 UI tests");
    false
}

fn platform() -> Win32Platform {
    Win32Platform::new().unwrap()
}

fn handles(p: &Win32Platform) -> HashSet<u64> {
    p.list_windows().unwrap().into_iter().map(|w| w.handle).collect()
}

/// Polls the listing until a window not in `before` matches `pick`.
fn wait_new(
    p: &Win32Platform,
    before: &HashSet<u64>,
    timeout: Duration,
    pick: impl Fn(&PlatformWindow) -> bool,
) -> Option<PlatformWindow> {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if let Some(w) = p.list_windows().unwrap().into_iter().find(|w| !before.contains(&w.handle) && pick(w)) {
            return Some(w);
        }
        sleep(Duration::from_millis(200));
    }
    None
}

/// Polls until the listed window `handle` satisfies `ok`; returns the last
/// listing of it either way.
fn wait_listed(
    p: &Win32Platform,
    handle: u64,
    timeout: Duration,
    ok: impl Fn(&PlatformWindow) -> bool,
) -> Option<PlatformWindow> {
    let start = Instant::now();
    let mut last = None;
    while start.elapsed() < timeout {
        last = p.list_windows().unwrap().into_iter().find(|w| w.handle == handle);
        if last.as_ref().is_some_and(&ok) {
            break;
        }
        sleep(Duration::from_millis(200));
    }
    last
}

/// The processes under `root`, for a failure message.
fn process_tree(root: u32) -> String {
    let procs = process_snapshot().unwrap_or_default();
    let mut out = String::new();
    let mut stack = vec![(root, 0usize)];
    let mut seen = HashSet::new();
    while let Some((pid, depth)) = stack.pop() {
        if !seen.insert(pid) {
            continue;
        }
        let Some(p) = procs.iter().find(|p| p.pid == pid) else { continue };
        out.push_str(&format!("{}{} {}\n", "  ".repeat(depth), p.pid, p.exe));
        for c in procs.iter().filter(|c| c.is_child_of(p)) {
            stack.push((c.pid, depth + 1));
        }
    }
    out
}

fn hwnd(handle: u64) -> HWND {
    HWND(handle as usize as *mut std::ffi::c_void)
}

/// A title marker unique to this test process and window.
fn new_marker(tag: &str) -> String {
    static N: AtomicU32 = AtomicU32::new(0);
    marker(std::process::id(), N.fetch_add(1, Ordering::SeqCst) + 1, tag)
}

/// cmd sets no title of its own and spec 5.1 leaves untitled windows out;
/// the `title` builtin names it without adding a child process.
fn cmd_titled(m: &str) -> String {
    format!("cmd.exe /K title {m}")
}

/// PowerShell titling its console, then running `then` (if any) in it.
fn powershell_titled(m: &str, then: &str) -> String {
    format!(r#"powershell.exe -NoLogo -NoExit -Command "$Host.UI.RawUI.WindowTitle='{m}'{then}""#)
}

/// Posts `WM_CLOSE` when dropped to a window another process owns, found by
/// this test's marker.
/// Only while `pid` still owns the handle: HWND values are reused, and a
/// handle this test found may name a user's window by the time it drops.
struct CloseOnDrop {
    handle: u64,
    pid: u32,
}

impl CloseOnDrop {
    fn of(w: &PlatformWindow) -> CloseOnDrop {
        CloseOnDrop { handle: w.handle, pid: w.pid }
    }
}

impl Drop for CloseOnDrop {
    fn drop(&mut self) {
        let h = hwnd(self.handle);
        let mut owner = 0u32;
        // SAFETY: a writable out pointer; any handle value is accepted.
        unsafe { windows::Win32::UI::WindowsAndMessaging::GetWindowThreadProcessId(h, Some(&mut owner)) };
        if owner == 0 || owner != self.pid {
            return;
        }
        // SAFETY: posting to a stale handle fails harmlessly.
        let _ = unsafe { PostMessageW(h, WM_CLOSE, WPARAM(0), LPARAM(0)) };
    }
}

/// `cmd /c start "" conhost.exe <args(marker)>`: a classic console with its
/// own window, even under CI's redirected stdio (spec 10.5). `args` must
/// make the shell title the console with the marker; only a new console
/// carrying it is taken (and later closed).
fn open_conhost(p: &Win32Platform, tag: &str, args: impl Fn(&str) -> String) -> (PlatformWindow, CloseOnDrop) {
    let m = new_marker(tag);
    let args = args(&m);
    let before = handles(p);
    Command::new("cmd.exe")
        .creation_flags(CREATE_NEW_CONSOLE)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .raw_arg(format!(r#"/c start "" conhost.exe {args}"#))
        .status()
        .unwrap();
    let w = wait_new(p, &before, Duration::from_secs(15), |w| {
        w.class_name == CONSOLE_CLASS && has_marker(&w.title, &m)
    })
    .unwrap_or_else(|| {
        panic!(
            "no new console window titled {m} for `{args}` in 15 s\nevery top-level {CONSOLE_CLASS} window:\n{}console processes:\n{}",
            p.explain_class(CONSOLE_CLASS),
            console_processes(),
        )
    });
    let guard = CloseOnDrop::of(&w);
    (w, guard)
}

/// Every conhost / OpenConsole / shell process with its parent, for a
/// failure message.
fn console_processes() -> String {
    const NAMES: [&str; 5] = ["conhost", "openconsole", "cmd", "powershell", "pwsh"];
    let procs = process_snapshot().unwrap_or_default();
    procs
        .iter()
        .filter(|p| NAMES.contains(&exe_stem(&p.exe).as_str()))
        .map(|p| format!("{} parent={} {}\n", p.pid, p.parent, p.exe))
        .collect()
}

fn assert_console_shell(p: &Win32Platform, tag: &str, args: impl Fn(&str) -> String, shell: Shell, app: &str) {
    let args_shown = args("<marker>");
    let (w, _close) = open_conhost(p, tag, args);
    let args = args_shown.as_str();
    let got = wait_listed(p, w.handle, Duration::from_secs(15), |w| w.shell == Some(shell));
    let tree = process_tree(w.pid);
    let got = got
        .unwrap_or_else(|| panic!("console for `{args}` left the listing\n{tree}{}", p.explain_class(CONSOLE_CLASS)));
    assert_eq!(got.terminal, Some(TerminalHost::Console), "{args}");
    assert_eq!(got.shell, Some(shell), "{args}; processes under the owner:\n{tree}");
    assert_eq!(got.app, app, "{args}");
    assert!(!got.title.is_empty());
    assert_eq!(p.current_shell(got.window_ref()).unwrap(), Some(shell), "{args}");
}

#[test]
fn classic_consoles_are_terminals_with_their_shell() {
    if !ui_enabled() {
        return;
    }
    let p = platform();
    assert_console_shell(&p, "ps", |m| powershell_titled(m, ""), Shell::PowerShell, "PowerShell");
    // A bare `cmd /K` under `start ""` can come up untitled (cmd, unlike
    // PowerShell, sets no title of its own), and spec 5.1 leaves untitled
    // windows out. `title` is a cmd builtin: it names the console the way a
    // shortcut or the Run box does, without adding a child process.
    assert_console_shell(&p, "cmd", cmd_titled, Shell::Cmd, "Command Prompt");
}

#[test]
fn a_program_running_in_the_shell_makes_it_unknown() {
    if !ui_enabled() {
        return;
    }
    let p = platform();
    // ping stands in for python / ssh / node: any non-shell child of the
    // shell is a program that would get our keys. The title is set first.
    let (w, _close) = open_conhost(&p, "busy", |m| powershell_titled(m, "; ping -n 120 127.0.0.1"));
    let got = wait_listed(&p, w.handle, Duration::from_secs(15), |w| w.shell == Some(Shell::Unknown));
    let tree = process_tree(w.pid);
    let got = got.unwrap_or_else(|| panic!("console left the listing\n{tree}"));
    assert_eq!(got.terminal, Some(TerminalHost::Console));
    assert_eq!(got.shell, Some(Shell::Unknown), "processes under the owner:\n{tree}");
    assert_eq!(got.app, "Console");
    assert_eq!(p.current_shell(got.window_ref()).unwrap(), Some(Shell::Unknown));
}

fn on_path(exe: &str) -> bool {
    Command::new("where.exe").arg(exe).stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success())
}

#[test]
fn windows_terminal_is_a_terminal_with_its_tab_shell() {
    if !ui_enabled() {
        return;
    }
    if !on_path("wt.exe") {
        eprintln!("skipped: wt.exe is not installed");
        return;
    }
    let p = platform();
    // The window shows its active tab's title, which the tab's PowerShell
    // sets to the marker.
    let m = new_marker("wt");
    let set_title = format!("$Host.UI.RawUI.WindowTitle='{m}'");
    let before = handles(&p);
    Command::new("wt.exe")
        .args(["-w", "new", "powershell.exe", "-NoLogo", "-NoExit", "-Command", &set_title])
        .status()
        .unwrap();
    let w = wait_new(&p, &before, Duration::from_secs(20), |w| w.class_name == WT_CLASS && has_marker(&w.title, &m))
        .unwrap_or_else(|| panic!("no new Windows Terminal window titled {m} in 20 s"));
    let _close = CloseOnDrop::of(&w);
    let got = wait_listed(&p, w.handle, Duration::from_secs(15), |w| w.shell == Some(Shell::PowerShell));
    let tree = process_tree(w.pid);
    let got = got.unwrap_or_else(|| panic!("Windows Terminal left the listing\n{tree}"));
    assert_eq!(got.terminal, Some(TerminalHost::WindowsTerminal));
    assert_eq!(got.app, "Windows Terminal");
    assert_eq!(got.shell, Some(Shell::PowerShell), "processes under WindowsTerminal.exe:\n{tree}");
    assert_eq!(p.current_shell(got.window_ref()).unwrap(), Some(Shell::PowerShell));
}

#[test]
fn notepad_is_an_app_not_a_terminal() {
    if !ui_enabled() {
        return;
    }
    let p = platform();
    // Notepad titles its window after the file it opens, so a file named
    // after the marker marks the window.
    let m = new_marker("notepad");
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join(format!("{m}.txt"));
    std::fs::write(&file, "").unwrap();
    let before = handles(&p);
    let mut child = Command::new("notepad.exe").arg(&file).spawn().unwrap();
    let w = wait_new(&p, &before, Duration::from_secs(15), |w| {
        w.exe_path.as_deref().map(exe_stem).as_deref() == Some("notepad") && has_marker(&w.title, &m)
    })
    .unwrap_or_else(|| panic!("no Notepad window titled {m} in 15 s"));
    let _close = CloseOnDrop::of(&w);
    assert_eq!(w.terminal, None);
    assert_eq!(w.shell, None);
    assert!(w.app.eq_ignore_ascii_case("notepad"), "FileDescription or exe stem, not the OS product name: {:?}", w.app);
    assert_eq!(p.current_shell(w.window_ref()).unwrap(), None);
    assert!(w.visible.width > 0 && w.visible.height > 0);
    assert!(w.outer.width >= w.visible.width && w.outer.height >= w.visible.height, "{w:?}");
    let _ = child.kill();
    let _ = child.wait();
}

/// A window of this process, destroyed when dropped.
struct OwnWindow(HWND);

impl OwnWindow {
    fn new(ex: WINDOW_EX_STYLE, style: WINDOW_STYLE, title: PCWSTR, owner: Option<&OwnWindow>) -> OwnWindow {
        // SAFETY: STATIC is a system class; the strings are static; the
        // owner, if any, is a live window of this thread.
        let h = unsafe {
            CreateWindowExW(
                ex,
                w!("STATIC"),
                title,
                style,
                100,
                120,
                640,
                480,
                owner.map(|o| o.0).unwrap_or_default(),
                None,
                None,
                None,
            )
        }
        .unwrap();
        OwnWindow(h)
    }
    fn handle(&self) -> u64 {
        self.0 .0 as usize as u64
    }
    fn rect(&self) -> PixelRect {
        let mut r = RECT::default();
        // SAFETY: a live window of this thread and a writable RECT.
        unsafe { GetWindowRect(self.0, &mut r) }.unwrap();
        PixelRect::new(r.left, r.top, r.right - r.left, r.bottom - r.top)
    }
}

impl Drop for OwnWindow {
    fn drop(&mut self) {
        // SAFETY: a window this thread created and nothing else destroys.
        let _ = unsafe { DestroyWindow(self.0) };
    }
}

#[test]
fn the_filter_keeps_only_plain_app_windows_and_minimized_ones_report_their_restored_rect() {
    if !ui_enabled() {
        return;
    }
    // Built before any window, so this process is per-monitor DPI aware v2.
    let default = platform();
    let p = platform().including_own_windows();
    let top = WS_OVERLAPPEDWINDOW | WS_VISIBLE;
    let plain = OwnWindow::new(WINDOW_EX_STYLE(0), top, w!("quip-test-plain"), None);
    let tool = OwnWindow::new(WS_EX_TOOLWINDOW, top, w!("quip-test-tool"), None);
    let cloaked = OwnWindow::new(WINDOW_EX_STYLE(0), top, w!("quip-test-cloaked"), None);
    let cloak = BOOL(1);
    // SAFETY: a live window of this thread; the value is a BOOL and its size
    // goes with it.
    unsafe {
        DwmSetWindowAttribute(cloaked.0, DWMWA_CLOAK, &cloak as *const BOOL as *const _, size_of::<BOOL>() as u32)
    }
    .unwrap();
    let owned =
        OwnWindow::new(WINDOW_EX_STYLE(0), WS_POPUP | WS_CAPTION | WS_VISIBLE, w!("quip-test-owned"), Some(&plain));
    let untitled = OwnWindow::new(WINDOW_EX_STYLE(0), top, w!(""), None);
    let hidden = OwnWindow::new(WINDOW_EX_STYLE(0), WS_OVERLAPPEDWINDOW, w!("quip-test-hidden"), None);
    let minimized = OwnWindow::new(WINDOW_EX_STYLE(0), top, w!("quip-test-minimized"), None);
    let restored = minimized.rect();
    // SAFETY: a live window of this thread.
    let _ = unsafe { ShowWindow(minimized.0, SW_MINIMIZE) };

    let listed: Vec<PlatformWindow> = p.list_windows().unwrap();
    let find = |w: &OwnWindow| listed.iter().find(|l| l.handle == w.handle());
    let plain_row = find(&plain).expect("a plain titled window is listed");
    assert_eq!(plain_row.title, "quip-test-plain");
    assert_eq!(plain_row.terminal, None);
    assert_eq!(plain_row.pid, std::process::id());
    for (name, w) in
        [("tool", &tool), ("cloaked", &cloaked), ("owned", &owned), ("untitled", &untitled), ("hidden", &hidden)]
    {
        assert!(find(w).is_none(), "{name} window must not be listed");
    }

    let min = find(&minimized).expect("a minimized window stays listed");
    assert!(min.is_minimized);
    assert!(!min.is_maximized);
    assert_eq!(min.outer, restored, "the restored rect, not the parking spot");
    assert_eq!(min.visible, restored);

    let mine: HashSet<u64> = [&plain, &minimized].iter().map(|w| w.handle()).collect();
    assert!(
        default.list_windows().unwrap().iter().all(|w| !mine.contains(&w.handle)),
        "Quip's own windows are never listed by default"
    );
}

#[test]
fn foreground_window_names_its_owner() {
    if !ui_enabled() {
        return;
    }
    let p = platform();
    if let Some(WindowRef { handle, pid }) = p.foreground_window().unwrap() {
        let mut owner = 0u32;
        // SAFETY: a writable out pointer; any handle value is accepted.
        unsafe { windows::Win32::UI::WindowsAndMessaging::GetWindowThreadProcessId(hwnd(handle), Some(&mut owner)) };
        assert_eq!(owner, pid);
    }
}

/// R2 finding 6: the selftest ends a leftover process only when the pid
/// still names the process it listed (creation time), never a newer one
/// that got the pid. A child of this test, with no window.
#[test]
fn terminate_if_same_ends_only_the_listed_process() {
    if !ui_enabled() {
        return;
    }
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let mut child = Command::new("ping.exe")
        .args(["-n", "60", "127.0.0.1"])
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let pid = child.id();
    let listed = process_snapshot().unwrap().into_iter().find(|p| p.pid == pid).expect("the child is listed");
    let created = listed.created.expect("its creation time is readable");
    assert!(!terminate_if_same(pid, Some(created + 1)), "another start time: not ours");
    assert!(!terminate_if_same(pid, None), "no start time: cannot tell");
    sleep(Duration::from_millis(200));
    assert!(child.try_wait().unwrap().is_none(), "still running after both refusals");
    assert!(terminate_if_same(pid, Some(created)));
    let start = Instant::now();
    while child.try_wait().unwrap().is_none() && start.elapsed() < Duration::from_secs(5) {
        sleep(Duration::from_millis(50));
    }
    assert!(child.try_wait().unwrap().is_some(), "ended");
}
