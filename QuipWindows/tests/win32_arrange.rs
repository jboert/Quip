//! Spec 10.5, arrange: the real Win32 backend moving, restoring, minimizing
//! and closing real windows. Only with `QUIP_WIN_UI=1` (Windows CI sets it;
//! `--test-threads=1`, they share the desktop).
//!
//! Every window here is the test's own: an in-process `OwnWindow`, or a
//! console carrying a title marker it set (`selftest::own::marker`). Targets
//! are built from those windows only, never from a desktop listing, so a
//! window the user has open is never moved, minimized or closed.
//!
//! `arrange::execute` runs on the thread that created the own windows: a
//! cross-thread `SetWindowPos` to a thread that pumps no messages would
//! block.
#![cfg(windows)]

use std::collections::HashSet;
use std::os::windows::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread::sleep;
use std::time::{Duration, Instant};

use quip_windows::platform::traits::{PlatformError, PlatformWindow, WindowBackend, WindowMove, WindowRef};
use quip_windows::platform::win32::Win32Platform;
use quip_windows::protocol::types::ArrangeLayout;
use quip_windows::selftest::own::{has_marker, marker};
use quip_windows::services::arrange::{self, Target, TargetResult};
use quip_windows::services::classify::CONSOLE_CLASS;
use quip_windows::services::layout::{self, PixelRect};
use windows::core::w;
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DestroyWindow, IsIconic, IsWindow, PostMessageW, ShowWindow, SW_MINIMIZE, WINDOW_EX_STYLE,
    WM_CLOSE, WS_OVERLAPPEDWINDOW, WS_VISIBLE,
};

const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;

fn ui_enabled() -> bool {
    if std::env::var("QUIP_WIN_UI").as_deref() == Ok("1") {
        return true;
    }
    eprintln!("skipped: set QUIP_WIN_UI=1 to run the Win32 UI tests");
    false
}

fn hwnd(handle: u64) -> HWND {
    HWND(handle as usize as *mut std::ffi::c_void)
}

fn work_area(p: &Win32Platform) -> PixelRect {
    let displays = p.list_displays().unwrap();
    displays.iter().find(|d| d.is_primary).expect("a primary display").work_area
}

/// A plain top-level window of this process and thread, destroyed when
/// dropped.
struct OwnWindow(HWND);

impl OwnWindow {
    fn new() -> OwnWindow {
        // SAFETY: STATIC is a system class; the strings are static.
        let h = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("STATIC"),
                w!("quip-test-arrange"),
                WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                150,
                130,
                500,
                400,
                None,
                None,
                None,
                None,
            )
        }
        .unwrap();
        OwnWindow(h)
    }
    fn window_ref(&self) -> WindowRef {
        WindowRef { handle: self.0 .0 as usize as u64, pid: std::process::id() }
    }
}

impl Drop for OwnWindow {
    fn drop(&mut self) {
        // SAFETY: a window this thread created; destroying it twice fails
        // harmlessly.
        let _ = unsafe { DestroyWindow(self.0) };
    }
}

/// Posts `WM_CLOSE` when dropped to a console this test opened.
struct CloseOnDrop(u64);

impl Drop for CloseOnDrop {
    fn drop(&mut self) {
        // SAFETY: posting to a stale handle fails harmlessly.
        let _ = unsafe { PostMessageW(hwnd(self.0), WM_CLOSE, WPARAM(0), LPARAM(0)) };
    }
}

fn new_marker(tag: &str) -> String {
    static N: AtomicU32 = AtomicU32::new(0);
    marker(std::process::id(), N.fetch_add(1, Ordering::SeqCst) + 1, tag)
}

/// A classic console titled with a marker of this test, found by it.
fn open_console(p: &Win32Platform, tag: &str) -> (PlatformWindow, CloseOnDrop, String) {
    let m = new_marker(tag);
    let before: HashSet<u64> = p.list_windows().unwrap().into_iter().map(|w| w.handle).collect();
    Command::new("cmd.exe")
        .creation_flags(CREATE_NEW_CONSOLE)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .raw_arg(format!(r#"/c start "" conhost.exe cmd.exe /K title {m}"#))
        .status()
        .unwrap();
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(15) {
        let found = p
            .list_windows()
            .unwrap()
            .into_iter()
            .find(|w| !before.contains(&w.handle) && w.class_name == CONSOLE_CLASS && has_marker(&w.title, &m));
        if let Some(w) = found {
            let guard = CloseOnDrop(w.handle);
            return (w, guard, m);
        }
        sleep(Duration::from_millis(200));
    }
    panic!("no new console window titled {m} in 15 s\n{}", p.explain_class(CONSOLE_CLASS));
}

fn targets_for(windows: &[WindowRef], layout: ArrangeLayout, work: PixelRect, restore_first: bool) -> Vec<Target> {
    windows
        .iter()
        .zip(layout::arrange(layout, windows.len(), work))
        .enumerate()
        .map(|(i, (&window, visible))| Target { id: format!("own-{i}"), window, visible, restore_first })
        .collect()
}

/// Arranges `windows` (all the test's own) and asserts every one moved and
/// their visible rects tile the work area within 1 px.
fn assert_arranges(p: &Win32Platform, windows: &[WindowRef], layout: ArrangeLayout, restore_first: bool) {
    let work = work_area(p);
    let targets = targets_for(windows, layout, work, restore_first);
    let results = arrange::execute(p, &targets, arrange::SETTLE);
    let got: Vec<PixelRect> = windows.iter().map(|&w| p.rects(w).unwrap().visible).collect();
    let wanted: Vec<PixelRect> = targets.iter().map(|t| t.visible).collect();
    assert!(
        results.iter().all(|r| *r == TargetResult::Moved),
        "{layout:?}: {results:?}\ngot {got:?}\nwanted {wanted:?}"
    );
    let problems = arrange::tiling_problems(layout, work, &got);
    assert!(problems.is_empty(), "{layout:?} on {work:?}: {problems:?}\ngot {got:?}\nwanted {wanted:?}");
}

#[test]
fn two_own_plain_windows_tile_with_no_gap() {
    if !ui_enabled() {
        return;
    }
    let p = Win32Platform::new().unwrap();
    let (a, b) = (OwnWindow::new(), OwnWindow::new());
    let refs = [a.window_ref(), b.window_ref()];
    assert_arranges(&p, &refs, ArrangeLayout::Horizontal, false);
    assert_arranges(&p, &refs, ArrangeLayout::Vertical, false);
}

#[test]
fn a_minimized_own_window_is_restored_and_tiled() {
    if !ui_enabled() {
        return;
    }
    let p = Win32Platform::new().unwrap();
    let (a, b) = (OwnWindow::new(), OwnWindow::new());
    // SAFETY: a live window of this thread.
    let _ = unsafe { ShowWindow(a.0, SW_MINIMIZE) };
    assert!(p.rects(a.window_ref()).unwrap().is_minimized);
    assert_arranges(&p, &[a.window_ref(), b.window_ref()], ArrangeLayout::Horizontal, true);
    // SAFETY: any handle value is accepted.
    assert!(!unsafe { IsIconic(a.0) }.as_bool(), "restored");
}

#[test]
fn two_own_consoles_tile_with_no_gap() {
    if !ui_enabled() {
        return;
    }
    let p = Win32Platform::new().unwrap();
    let (a, _close_a, _) = open_console(&p, "arr-a");
    let (b, _close_b, _) = open_console(&p, "arr-b");
    let refs = [a.window_ref(), b.window_ref()];
    assert_arranges(&p, &refs, ArrangeLayout::Horizontal, false);
    assert_arranges(&p, &refs, ArrangeLayout::Vertical, false);
}

#[test]
fn a_closed_own_window_is_gone() {
    if !ui_enabled() {
        return;
    }
    let p = Win32Platform::new().unwrap();
    let gone = {
        let w = OwnWindow::new();
        w.window_ref()
    };
    assert_eq!(p.rects(gone), Err(PlatformError::WindowGone));
    assert_eq!(p.restore(gone), Err(PlatformError::WindowGone));
    let mv = WindowMove { window: gone, outer: PixelRect::new(0, 0, 300, 200) };
    assert_eq!(p.move_windows(&[mv]), vec![Err(PlatformError::WindowGone)]);
    assert_eq!(p.minimize(gone), Err(PlatformError::WindowGone));
    assert_eq!(p.close(gone), Err(PlatformError::WindowGone));
    let work = work_area(&p);
    let t = targets_for(&[gone], ArrangeLayout::Horizontal, work, true);
    assert_eq!(arrange::execute(&p, &t, arrange::SETTLE), vec![TargetResult::Gone]);
}

fn wait_until(timeout: Duration, mut done: impl FnMut() -> bool) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if done() {
            return true;
        }
        sleep(Duration::from_millis(100));
    }
    done()
}

#[test]
fn minimize_then_close_an_own_console() {
    if !ui_enabled() {
        return;
    }
    let p = Win32Platform::new().unwrap();
    let (c, _close, m) = open_console(&p, "min-close");
    let r = c.window_ref();
    p.minimize(r).unwrap();
    // SAFETY: any handle value is accepted.
    assert!(wait_until(Duration::from_secs(5), || unsafe { IsIconic(hwnd(r.handle)) }.as_bool()), "iconic");
    p.close(r).unwrap();
    let closed = wait_until(Duration::from_secs(5), || {
        // SAFETY: any handle value is accepted.
        let alive = unsafe { IsWindow(hwnd(r.handle)) }.as_bool();
        let marked =
            p.list_windows().unwrap().iter().any(|w| w.class_name == CONSOLE_CLASS && has_marker(&w.title, &m));
        !alive && !marked
    });
    assert!(closed, "the marked console is gone within 5 s");
}
