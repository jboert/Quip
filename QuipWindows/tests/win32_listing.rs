//! Spec 10.5, listing: the real Win32 backend against real windows. They
//! open consoles, Windows Terminal and Notepad, so they only run with
//! `QUIP_WIN_UI=1` (Windows CI sets it; run them one at a time with
//! `--test-threads=1`, they share the desktop).
#![cfg(windows)]

use std::collections::HashSet;
use std::os::windows::process::CommandExt;
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

use quip_windows::platform::traits::{PlatformWindow, WindowBackend, WindowRef};
use quip_windows::platform::win32::{process_snapshot, Win32Platform};
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
        if let Some(p) = procs.iter().find(|p| p.pid == pid) {
            out.push_str(&format!("{}{} {}\n", "  ".repeat(depth), p.pid, p.exe));
        }
        for c in procs.iter().filter(|c| c.parent == pid && c.pid != pid) {
            stack.push((c.pid, depth + 1));
        }
    }
    out
}

fn hwnd(handle: u64) -> HWND {
    HWND(handle as usize as *mut std::ffi::c_void)
}

/// Posts `WM_CLOSE` to a window another process owns when dropped.
struct CloseOnDrop(u64);

impl Drop for CloseOnDrop {
    fn drop(&mut self) {
        // SAFETY: posting to a stale handle fails harmlessly.
        let _ = unsafe { PostMessageW(hwnd(self.0), WM_CLOSE, WPARAM(0), LPARAM(0)) };
    }
}

/// `cmd /c start "" conhost.exe <args>`: a classic console with its own
/// window, even under CI's redirected stdio (spec 10.5).
fn open_conhost(p: &Win32Platform, args: &str) -> (PlatformWindow, CloseOnDrop) {
    let before = handles(p);
    Command::new("cmd.exe")
        .creation_flags(CREATE_NEW_CONSOLE)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .raw_arg(format!(r#"/c start "" conhost.exe {args}"#))
        .status()
        .unwrap();
    let w = wait_new(p, &before, Duration::from_secs(15), |w| w.class_name == CONSOLE_CLASS)
        .unwrap_or_else(|| panic!("no new console window for `{args}` in 15 s"));
    let guard = CloseOnDrop(w.handle);
    (w, guard)
}

fn assert_console_shell(p: &Win32Platform, args: &str, shell: Shell, app: &str) {
    let (w, _close) = open_conhost(p, args);
    let got = wait_listed(p, w.handle, Duration::from_secs(15), |w| w.shell == Some(shell));
    let tree = process_tree(w.pid);
    let got = got.unwrap_or_else(|| panic!("console for `{args}` left the listing\n{tree}"));
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
    assert_console_shell(&p, "powershell.exe -NoLogo -NoExit", Shell::PowerShell, "PowerShell");
    assert_console_shell(&p, "cmd.exe /K", Shell::Cmd, "Command Prompt");
}

#[test]
fn a_program_running_in_the_shell_makes_it_unknown() {
    if !ui_enabled() {
        return;
    }
    let p = platform();
    // ping stands in for python / ssh / node: any non-shell child of the
    // shell is a program that would get our keys.
    let (w, _close) = open_conhost(&p, "powershell.exe -NoLogo -NoExit -Command ping -n 120 127.0.0.1");
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
    let before = handles(&p);
    Command::new("wt.exe").args(["-w", "new", "powershell.exe", "-NoLogo", "-NoExit"]).status().unwrap();
    let w = wait_new(&p, &before, Duration::from_secs(20), |w| w.class_name == WT_CLASS)
        .expect("no new Windows Terminal window in 20 s");
    let _close = CloseOnDrop(w.handle);
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
    let before = handles(&p);
    let mut child = Command::new("notepad.exe").spawn().unwrap();
    let w = wait_new(&p, &before, Duration::from_secs(15), |w| {
        w.exe_path.as_deref().map(exe_stem).as_deref() == Some("notepad")
    })
    .expect("no Notepad window in 15 s");
    let _close = CloseOnDrop(w.handle);
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
