//! Spec 6 on real Windows: single instance, the "Start with Windows" Run
//! value, the tray icon. Gated by `QUIP_WIN_UI=1` like the other Win32 tests.
#![cfg(windows)]

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use quip_windows::tray::autostart;
use quip_windows::tray::instance::{self, Acquired};
use quip_windows::tray::win32::{HiddenWindow, NotifyIcon};
use quip_windows::tray::{icon, menu};

fn ui_enabled() -> bool {
    if std::env::var("QUIP_WIN_UI").as_deref() == Ok("1") {
        return true;
    }
    eprintln!("skipped: set QUIP_WIN_UI=1 to run the Win32 UI tests");
    false
}

#[test]
fn a_second_launch_exits_with_0_within_a_second() {
    if !ui_enabled() {
        return;
    }
    // This test plays the first Quip by holding the mutex itself, so the
    // launched one must be the second.
    let _first = match instance::acquire().unwrap() {
        Acquired::First(guard) => Some(guard),
        Acquired::AlreadyRunning => None,
    };
    let tmp = tempfile::tempdir().unwrap();
    let started = Instant::now();
    // If the check ever failed, this Quip would start for real: point its
    // settings and logs at a temp folder so it cannot touch the user's.
    let mut child = Command::new(env!("CARGO_BIN_EXE_Quip"))
        .env("APPDATA", tmp.path().join("Roaming"))
        .env("LOCALAPPDATA", tmp.path().join("Local"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let status = loop {
        if let Some(s) = child.try_wait().unwrap() {
            break s;
        }
        if started.elapsed() > Duration::from_secs(5) {
            let _ = child.kill();
            panic!("the second Quip was still running after 5 s");
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let took = started.elapsed();
    eprintln!("second launch exited with {status} after {took:?}");
    assert_eq!(status.code(), Some(0));
    assert!(took < Duration::from_secs(1), "{took:?}");
    assert!(!tmp.path().join("Roaming").join("Quip").exists(), "it must not read or make settings");
}

/// Puts the Run value back as it was, even when an assert fails.
struct RestoreRunValue(Option<String>);

impl Drop for RestoreRunValue {
    fn drop(&mut self) {
        let _ = match &self.0 {
            Some(v) => autostart::write(v),
            None => autostart::remove(),
        };
    }
}

#[test]
fn start_with_windows_writes_and_removes_the_run_value() {
    if !ui_enabled() {
        return;
    }
    let before = autostart::read().unwrap();
    let restore = RestoreRunValue(before.clone());
    let exe = std::path::PathBuf::from(r"C:\Quip test dir\Quip.exe");
    let value = autostart::run_value(&exe);

    autostart::write(&value).unwrap();
    let got = autostart::read().unwrap();
    assert_eq!(got.as_deref(), Some(r#""C:\Quip test dir\Quip.exe""#));
    assert!(autostart::points_at(got.as_deref().unwrap(), &exe));

    autostart::remove().unwrap();
    assert_eq!(autostart::read().unwrap(), None);
    autostart::remove().unwrap();

    autostart::round_trip(&exe).unwrap();
    assert_eq!(autostart::read().unwrap(), None, "round_trip puts back what was there: nothing");
    drop(restore);
    assert_eq!(autostart::read().unwrap(), before, "the user's value is back");
}

#[test]
fn the_tray_icon_is_added_and_removed() {
    if !ui_enabled() {
        return;
    }
    let window = HiddenWindow::new().unwrap();
    let hicon = icon::create().unwrap();
    let id = 77;
    let added = NotifyIcon::add(window.hwnd(), id, hicon, "Quip test").unwrap();
    assert!(NotifyIcon::is_present(window.hwnd(), id, "Quip test"), "added");
    drop(added);
    assert!(!NotifyIcon::is_present(window.hwnd(), id, "Quip test"), "removed");
    // The menu the icon opens is built from data; every action has an id.
    let entries = menu::build(&menu::TrayStatus {
        phones: 0,
        pin: "12345678".into(),
        addresses: vec![],
        port: 8765,
        show_all_apps: false,
        start_with_windows: false,
    });
    assert_eq!(entries.len(), 12);
    // SAFETY: the icon is ours and no longer shown.
    let _ = unsafe { windows::Win32::UI::WindowsAndMessaging::DestroyIcon(hicon) };
}
