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
    assert_eq!(autostart::read().unwrap(), None, "round_trip leaves Quip alone: still nothing");
    // With a Quip value set, round_trip leaves it exactly as it was and
    // leaves no value of its own behind.
    let users = autostart::run_value(std::path::Path::new(r"D:\Other Quip\Quip.exe"));
    autostart::write(&users).unwrap();
    autostart::round_trip(&exe).unwrap();
    assert_eq!(autostart::read().unwrap().as_deref(), Some(users.as_str()), "Quip is untouched");
    let own = autostart::selftest_value_name(std::process::id());
    assert_eq!(autostart::read_named(&own).unwrap(), None, "{own} is deleted");
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

/// Spec 9: Explorer shows Quip's icon and version for the exe (the
/// resource `build.rs` compiles).
#[test]
fn the_exe_has_an_icon_and_a_version_resource() {
    use windows::core::{HSTRING, PCWSTR};
    use windows::Win32::Storage::FileSystem::{GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW};
    use windows::Win32::UI::Shell::ExtractIconExW;

    if !ui_enabled() {
        return;
    }
    let exe = HSTRING::from(env!("CARGO_BIN_EXE_Quip"));
    // SAFETY: index -1 with no out arrays asks only for the icon count.
    let icons = unsafe { ExtractIconExW(&exe, -1, None, None, 0) };
    assert!(icons >= 1, "Quip.exe holds {icons} icons");

    // SAFETY: a valid path; no handle is returned.
    let size = unsafe { GetFileVersionInfoSizeW(&exe, None) };
    assert!(size > 0, "no version resource");
    let mut data = vec![0u8; size as usize];
    // SAFETY: `data` holds `size` writable bytes for the call.
    unsafe { GetFileVersionInfoW(&exe, 0, size, data.as_mut_ptr().cast()) }.unwrap();
    let query = |key: &str| -> String {
        let sub = HSTRING::from(format!(r"\StringFileInfo\040904B0\{key}"));
        let mut ptr: *mut std::ffi::c_void = std::ptr::null_mut();
        let mut len = 0u32;
        // SAFETY: `data` is the block GetFileVersionInfoW filled; the out
        // pointer then points inside it, `len` UTF-16 units with the NUL.
        let ok = unsafe { VerQueryValueW(data.as_ptr().cast(), PCWSTR(sub.as_ptr()), &mut ptr, &mut len) };
        assert!(ok.as_bool() && !ptr.is_null(), "no {key}");
        // SAFETY: as above; the block outlives this slice.
        let units = unsafe { std::slice::from_raw_parts(ptr as *const u16, len as usize) };
        String::from_utf16_lossy(units).trim_end_matches('\0').to_string()
    };
    assert_eq!(query("FileVersion"), env!("CARGO_PKG_VERSION"));
    assert_eq!(query("ProductName"), "Quip");
    assert_eq!(query("FileDescription"), "Quip for Windows");
    assert_eq!(query("Comments"), quip_windows::build_info::BUILD, "the commit stamp");
}
