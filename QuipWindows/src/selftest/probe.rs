//! `Quip.exe --input-probe <marker>` (internal, for the selftest's
//! `elevated_target_types_nothing` case): what happens when Quip types at a
//! window ABOVE its own integrity level.
//!
//! The selftest starts it one level below itself (`win32::integrity::
//! spawn_at_integrity`), with one of its own windows in front. It acts only
//! when the window in front carries `<marker>` (`own::has_marker`); else it
//! sends nothing and exits 2. It never focuses anything. It runs
//! `injector::execute(&[Type(<marker>)])` (no focus step), then, only when
//! `QUIP_SELFTEST_RAW_PROBE=1` (CI sets it; `selftest::RAW_PROBE_ENV`), ONE
//! raw `SendInput` of the same text that bypasses the injector, to learn
//! what Windows returns under UIPI (the `SendInput` docs say the count does
//! not show it). Before the raw call it checks the marker window is still in
//! front, but focus can still move between that check and the send, and the
//! text would then land in a user's window: so on the owner's PC it is
//! skipped (`raw_inserted=skipped(...)`). It prints one line,
//! `access=<…> injector=<error or ok> raw_inserted=<n or skipped(...)>`, and
//! exits 0.

use super::own::has_marker;
use super::{raw_probe_enabled, RAW_PROBE_ENV};
use crate::platform::traits::{WindowBackend, WindowRef};
use crate::platform::win32::{raw_send_units, window_title, Win32Platform};
use crate::services::injector::{self, Step};

pub const FLAG: &str = "--input-probe";

/// The marker window in front, or why not.
fn marked_front(p: &Win32Platform, marker: &str) -> Result<WindowRef, String> {
    match p.foreground_window() {
        Ok(Some(w)) if has_marker(&window_title(w.handle), marker) => Ok(w),
        Ok(Some(_)) => Err("the window in front does not carry the marker".into()),
        Ok(None) => Err("no window in front".into()),
        Err(e) => Err(format!("foreground_window: {e}")),
    }
}

pub fn run(marker: &str) -> i32 {
    if marker.is_empty() || marker.starts_with('-') {
        eprintln!("usage: Quip {FLAG} <marker>");
        return 2;
    }
    let p = match Win32Platform::new() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("probe: {e}");
            return 2;
        }
    };
    let w = match marked_front(&p, marker) {
        Ok(w) => w,
        Err(e) => {
            println!("probe: {e}; nothing sent");
            return 2;
        }
    };
    let access = p.input_access(w).map(|a| a.as_str().to_string()).unwrap_or_else(|e| format!("error({e})"));
    let report = injector::execute(&p, w, &[Step::Type(marker.to_string())]);
    let injector = match &report.error {
        None => "ok".to_string(),
        Some(e) => e.to_string(),
    };
    let raw = match marked_front(&p, marker) {
        _ if !raw_probe_enabled(std::env::var(RAW_PROBE_ENV).ok().as_deref()) => {
            format!("skipped(set {RAW_PROBE_ENV}=1 to run it; CI only)")
        }
        Ok(again) if again == w => {
            let units: Vec<u16> = marker.encode_utf16().collect();
            raw_send_units(&units).to_string()
        }
        _ => "skipped(focus moved)".to_string(),
    };
    println!("access={access} injector={injector} raw_inserted={raw} own_rid={:#x}", p.own_rid());
    0
}
