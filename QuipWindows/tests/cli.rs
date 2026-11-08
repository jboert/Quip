//! `Quip.exe` command lines that need no platform (spec 9): run the real
//! binary on any OS.

use std::process::Command;

#[test]
fn version_prints_the_build_stamp_and_exits_0() {
    let out = Command::new(env!("CARGO_BIN_EXE_Quip")).arg("--version").output().unwrap();
    assert_eq!(out.status.code(), Some(0), "{out:?}");
    let text = String::from_utf8(out.stdout).unwrap();
    let line = text.trim_end_matches(['\r', '\n']);
    let re = regex::Regex::new(r"^Quip for Windows \d+\.\d+\.\d+( \([0-9a-f]{12}(-dirty)?\))?$").unwrap();
    assert!(re.is_match(line), "{line:?}");
    assert!(line.starts_with(&format!("Quip for Windows {}", env!("CARGO_PKG_VERSION"))), "{line:?}");
    assert_eq!(text.lines().count(), 1, "one line: {text:?}");
}

#[test]
fn help_lists_version() {
    let out = Command::new(env!("CARGO_BIN_EXE_Quip")).arg("--help").output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert!(String::from_utf8(out.stdout).unwrap().contains("Quip --version"));
}
