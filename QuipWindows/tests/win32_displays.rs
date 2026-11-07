//! Spec 10.5, displays: the real monitors, and the frames the host derives
//! from them. Gated by `QUIP_WIN_UI=1` like the other Win32 tests.
#![cfg(windows)]

use std::collections::HashMap;

use quip_windows::app_state::AppState;
use quip_windows::platform::traits::WindowBackend;
use quip_windows::platform::win32::Win32Platform;

fn ui_enabled() -> bool {
    if std::env::var("QUIP_WIN_UI").as_deref() == Ok("1") {
        return true;
    }
    eprintln!("skipped: set QUIP_WIN_UI=1 to run the Win32 UI tests");
    false
}

#[test]
fn at_least_one_display_and_exactly_one_primary_at_the_origin() {
    if !ui_enabled() {
        return;
    }
    let p = Win32Platform::new().unwrap();
    let displays = p.list_displays().unwrap();
    assert!(!displays.is_empty());
    let primaries: Vec<_> = displays.iter().filter(|d| d.is_primary).collect();
    assert_eq!(primaries.len(), 1, "{displays:?}");
    assert_eq!((primaries[0].bounds.x, primaries[0].bounds.y), (0, 0), "Windows puts the primary at the origin");
    for d in &displays {
        assert!(d.device_name.starts_with(r"\\.\"), "{d:?}");
        assert!(!d.name.is_empty(), "{d:?}");
        assert!(d.bounds.width > 0 && d.bounds.height > 0, "{d:?}");
        let (b, w) = (d.bounds, d.work_area);
        assert!(w.width > 0 && w.height > 0, "{d:?}");
        assert!(
            w.x >= b.x && w.y >= b.y && w.right() <= b.right() && w.bottom() <= b.bottom(),
            "work area inside: {d:?}"
        );
    }
}

#[test]
fn frames_of_windows_inside_a_display_are_inside_0_to_1() {
    if !ui_enabled() {
        return;
    }
    let p = Win32Platform::new().unwrap();
    let displays = p.list_displays().unwrap();
    let windows = p.list_windows().unwrap();
    let fg = p.foreground_window().unwrap();
    let mut state = AppState::new(HashMap::new(), true);
    state.update(windows, displays.clone(), fg);
    for t in state.windows() {
        let v = t.platform.visible;
        let inside = displays.iter().any(|d| {
            v.x >= d.bounds.x && v.y >= d.bounds.y && v.right() <= d.bounds.right() && v.bottom() <= d.bounds.bottom()
        });
        if !inside {
            continue;
        }
        let f = t.frame;
        for (what, x) in [("x", f.x), ("y", f.y), ("width", f.width), ("height", f.height)] {
            assert!((0.0..=1.0).contains(&x), "{what} of {:?} is {x}: {:?}", t.platform.title, f);
        }
        assert!(t.display_id.is_some());
    }
}
