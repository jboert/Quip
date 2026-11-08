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

fn check_stamp(stamp: &str, porcelain: &str) -> (Option<i32>, String) {
    use std::io::Write;
    let mut child = Command::new("bash")
        .arg(script())
        .arg("--check-stamp")
        .arg(stamp)
        .arg("-")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(porcelain.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr);
    (out.status.code(), text)
}

#[test]
fn a_clean_stamp_from_a_dirty_tree_fails() {
    let (code, text) = check_stamp("0.1.0 (0123456789ab)", " M Cargo.lock\n");
    assert_eq!(code, Some(1), "{text}");
    assert!(text.contains("Cargo.lock") && text.contains("stamped clean"), "{text}");
}

#[test]
fn a_dirty_stamp_from_a_clean_tree_fails() {
    let (code, text) = check_stamp("0.1.0 (0123456789ab-dirty)", "");
    assert_eq!(code, Some(1), "{text}");
    assert!(text.contains("stamped -dirty"), "{text}");
}

#[test]
fn a_stamp_that_matches_the_tree_passes() {
    let (code, text) = check_stamp("0.1.0 (0123456789ab)", "");
    assert_eq!(code, Some(0), "{text}");
    let (code, text) = check_stamp("0.1.0 (0123456789ab-dirty)", " M src/app.rs\n");
    assert_eq!(code, Some(0), "{text}");
}

/// The words between the quotes of `NAME="…"` (script) or the string
/// literals of `NAME: &[&str] = &[…]` (build.rs).
fn listed(text: &str, start: &str, end: char) -> Vec<String> {
    let at = text.find(start).unwrap_or_else(|| panic!("no {start}"));
    let rest = &text[at + start.len()..];
    let body = &rest[..rest.find(end).unwrap()];
    let mut v: Vec<String> = body
        .split(|c: char| c.is_whitespace() || c == ',' || c == '"')
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect();
    v.sort();
    v
}

#[test]
fn the_script_and_build_rs_check_the_same_build_inputs() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let build_rs = std::fs::read_to_string(root.join("build.rs")).unwrap();
    let sh = std::fs::read_to_string(script()).unwrap();
    let from_build = listed(&build_rs, "const BUILD_INPUTS: &[&str] = &[", ']');
    let from_sh = listed(&sh, "BUILD_INPUTS=\"", '"');
    assert_eq!(from_build, from_sh);
    for must in ["Cargo.lock", "Cargo.toml", "build.rs", "src"] {
        assert!(from_build.iter().any(|s| s == must), "{must} missing from {from_build:?}");
    }
    assert!(
        build_rs.contains("\"--untracked-files=no\", \"--\"") && build_rs.contains("cargo:rerun-if-changed={input}"),
        "build.rs limits `git status` to BUILD_INPUTS and reruns on each"
    );
}
