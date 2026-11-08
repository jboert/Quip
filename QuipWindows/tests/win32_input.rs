//! Spec 10.5, focus, typing and keys: the real Win32 backend and the shared
//! injector against real consoles. Only with `QUIP_WIN_UI=1` (Windows CI sets
//! it; `--test-threads=1`, they share the desktop).
//!
//! Each test runs the matching `--selftest` case through
//! `selftest::win32::run_named`, so the PC and CI check the same thing in
//! the same way. Every window is the test's own (a console or a Windows
//! Terminal window carrying a title marker it set), input goes only through
//! `injector::execute`, and the integrity probe is this build's `Quip.exe`.
#![cfg(windows)]

use std::path::PathBuf;

use quip_windows::selftest::report::Outcome;
use quip_windows::selftest::win32::run_named;

fn ui_enabled() -> bool {
    if std::env::var("QUIP_WIN_UI").as_deref() == Ok("1") {
        return true;
    }
    eprintln!("skipped: set QUIP_WIN_UI=1 to run the Win32 UI tests");
    false
}

/// Runs one case; a FAIL fails the test, and so does a SKIP unless
/// `may_skip` names its reason.
fn case(name: &str, may_skip: Option<&str>) {
    if !ui_enabled() {
        return;
    }
    let exe = PathBuf::from(env!("CARGO_BIN_EXE_Quip"));
    let results = run_named(&[name], exe).unwrap();
    assert_eq!(results.len(), 1);
    let r = &results[0];
    for n in &r.notes {
        eprintln!("note {name}: {n}");
    }
    match &r.outcome {
        Outcome::Pass => {}
        Outcome::Skip(why) if may_skip.is_some_and(|m| why.contains(m)) => eprintln!("skipped {name}: {why}"),
        other => panic!("{name}: {other:?}"),
    }
}

#[test]
fn focus_brings_an_own_console_from_behind_another() {
    case("focus_own_console", None);
}

#[test]
fn typed_marker_with_emoji_reads_back() {
    case("type_marker_read_back", None);
}

#[test]
fn multi_line_waits_for_return_in_powershell() {
    case("multi_line_waits_for_return", None);
}

#[test]
fn multi_line_to_cmd_types_nothing() {
    case("multi_line_refused_in_cmd", None);
}

#[test]
fn focus_stolen_mid_text_stops_typing() {
    case("focus_stolen_stops_typing", None);
}

#[test]
fn keys_arrive_as_the_spec_keys() {
    case("quick_keys_reach_own_console", None);
}

#[test]
fn ctrl_c_stops_ping() {
    case("ctrl_c_stops_ping", None);
}

#[test]
fn windows_terminal_types_and_reads_back() {
    case("windows_terminal_types_and_reads_back", Some("wt.exe"));
}

#[test]
fn a_lower_integrity_probe_is_blocked() {
    case("elevated_target_types_nothing", None);
}

#[test]
fn an_unknown_case_name_is_an_error() {
    if !ui_enabled() {
        return;
    }
    assert!(run_named(&["no_such_case"], PathBuf::from("Quip.exe")).is_err());
}
