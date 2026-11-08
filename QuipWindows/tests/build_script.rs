//! `tools/build-windows.sh --check-imports` (spec 9) against saved
//! `objdump -p` output, so the import allowlist is tested by `cargo test`
//! and `tools/check.sh` without a release build. Unix only: the script runs
//! on the Mac that builds the release.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::Command;

fn script() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../tools/build-windows.sh")
}

fn check(fixture: &str) -> (Option<i32>, String) {
    let file = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/build-windows").join(fixture);
    let out = Command::new("bash").arg(script()).arg("--check-imports").arg(file).output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr);
    (out.status.code(), text)
}

#[test]
fn todays_imports_pass() {
    let (code, text) = check("clean.txt");
    assert_eq!(code, Some(0), "{text}");
    assert!(text.contains("import check: ok"), "{text}");
}

#[test]
fn a_mingw_runtime_dll_fails_and_is_named() {
    let (code, text) = check("libgcc.txt");
    assert_eq!(code, Some(1), "{text}");
    assert!(text.contains("libgcc_s_seh-1.dll"), "{text}");
}

#[test]
fn an_unknown_dll_fails() {
    let (code, text) = check("unknown.txt");
    assert_eq!(code, Some(1), "{text}");
    assert!(text.contains("somevendor64.dll"), "{text}");
}

#[test]
fn output_with_no_imports_fails() {
    let (code, text) = check("no-imports.txt");
    assert_eq!(code, Some(1), "an objdump that failed must not pass: {text}");
}

#[test]
fn api_set_dlls_are_allowed() {
    let (_, text) = check("clean.txt");
    let fixture =
        std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/build-windows/clean.txt"))
            .unwrap();
    assert!(fixture.contains("api-ms-win-crt-runtime-l1-1-0.dll"), "the fixture holds API sets");
    assert!(!text.contains("api-ms-win"), "none is reported: {text}");
}

#[test]
fn bad_arguments_exit_2() {
    let out = Command::new("bash").arg(script()).arg("--check-imports").output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    let out = Command::new("bash").arg(script()).arg("--nope").output().unwrap();
    assert_eq!(out.status.code(), Some(2));
}
