//! `Quip.exe --selftest` (spec 10.5): the Win32 cases run on the PC through
//! the real app code, and a redacted PASS/FAIL report written to
//! `%LOCALAPPDATA%\Quip\Logs\selftest-<time>.txt` for the owner to send back.
//!
//! `report` (format, exit code, redaction) and `own` (which windows and
//! processes are the selftest's own) are pure and Mac-tested; `win32`
//! holds the case registry and runs it.

pub mod own;
#[cfg(windows)]
pub mod probe;
pub mod report;
#[cfg(windows)]
pub mod win32;

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Writes `text` as a new `selftest-<time>.txt` in `dir` (created if
/// missing). Never overwrites: a second run in the same second gets `-1`,
/// `-2`, ….
pub fn write_report(dir: &Path, unix_seconds: f64, text: &str) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    for attempt in 0..100 {
        let path = dir.join(report::file_name(unix_seconds, attempt));
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(mut f) => {
                f.write_all(text.as_bytes())?;
                return Ok(path);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(std::io::Error::new(std::io::ErrorKind::AlreadyExists, "100 selftest reports in one second"))
}

/// The switch for the probe's raw `SendInput` (`probe`): it bypasses the
/// injector, so if focus moved to a user's window between the check and
/// the send, marker text would land there. Only CI sets it
/// (`.github/workflows/windows.yml`); on the owner's PC the probe skips it.
pub const RAW_PROBE_ENV: &str = "QUIP_SELFTEST_RAW_PROBE";

/// `RAW_PROBE_ENV`'s value turns the raw send on: exactly `1`.
pub fn raw_probe_enabled(value: Option<&str>) -> bool {
    value == Some("1")
}

/// The `build_stamp` case: a build must name its commit, or a report from
/// it cannot be traced to code. `Ok` holds the commit.
pub fn check_build_stamp(build: &str) -> Result<String, String> {
    crate::build_info::sha_of(build)
        .map(str::to_string)
        .ok_or_else(|| format!("build {build:?} has no commit stamp; build it from a git checkout"))
}

/// The probe file `log_dir_writable` makes in the logs folder.
pub fn probe_file_name(pid: u32) -> String {
    format!("selftest-probe-{pid}.tmp")
}

/// The `log_dir_writable` case: creates (folder too, as the logs do),
/// writes and deletes `probe_file_name(pid)` in `dir`. A host that cannot
/// do this logs nothing at all.
pub fn check_log_dir_writable(dir: &Path, pid: u32) -> Result<(), String> {
    let at = |what: &str, e: std::io::Error| format!("{what} in {}: {e}", dir.display());
    std::fs::create_dir_all(dir).map_err(|e| at("cannot make the folder", e))?;
    let path = dir.join(probe_file_name(pid));
    let text = format!("quip selftest probe {pid}\n");
    // Plain create + truncate: a probe left by a killed run is overwritten,
    // and the read-back proves this run's write landed.
    std::fs::write(&path, &text).map_err(|e| at("cannot write a file", e))?;
    let back = std::fs::read_to_string(&path).map_err(|e| at("cannot read back a file", e))?;
    std::fs::remove_file(&path).map_err(|e| at("cannot delete a file", e))?;
    if back != text {
        return Err(format!("a file written in {} read back different", dir.display()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stamped_build_passes_with_its_commit() {
        assert_eq!(check_build_stamp("0.1.0 (a52c5e2abcde)"), Ok("a52c5e2abcde".into()));
        assert_eq!(check_build_stamp("0.1.0 (a52c5e2abcde-dirty)"), Ok("a52c5e2abcde".into()));
    }

    #[test]
    fn an_unstamped_build_fails() {
        let e = check_build_stamp("0.1.0").unwrap_err();
        assert!(e.contains("no commit"), "{e}");
    }

    #[test]
    fn the_log_dir_probe_leaves_nothing_behind() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("Quip").join("Logs");
        check_log_dir_writable(&dir, 42).unwrap();
        assert!(dir.is_dir(), "the folder is made, as the logs make it");
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0, "the probe file is gone");
    }

    #[test]
    fn an_unwritable_log_dir_fails_and_says_where() {
        let tmp = tempfile::tempdir().unwrap();
        // A file where the folder should be: nothing can be made inside it.
        let dir = tmp.path().join("Logs");
        std::fs::write(&dir, "not a folder").unwrap();
        let e = check_log_dir_writable(&dir, 42).unwrap_err();
        assert!(e.contains("Logs"), "{e}");
    }

    #[test]
    fn the_probe_file_is_named_for_the_selftest_and_its_pid() {
        // The README and the safety rules name this file; it never collides
        // with a log or a report.
        assert_eq!(probe_file_name(42), "selftest-probe-42.tmp");
    }

    #[test]
    fn a_leftover_probe_file_is_not_trusted() {
        // A stale probe from a killed run must not count as a write.
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join(probe_file_name(42)), "old").unwrap();
        check_log_dir_writable(tmp.path(), 42).unwrap();
        assert!(!tmp.path().join(probe_file_name(42)).exists());
    }

    #[test]
    fn a_report_is_written_into_a_new_folder_and_never_overwritten() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("Quip").join("Logs");
        let first = write_report(&dir, 1_800_000_000.0, "one\n").unwrap();
        let second = write_report(&dir, 1_800_000_000.0, "two\n").unwrap();
        assert_eq!(first, dir.join("selftest-20270115T080000Z.txt"));
        assert_eq!(second, dir.join("selftest-20270115T080000Z-1.txt"));
        assert_eq!(std::fs::read_to_string(first).unwrap(), "one\n");
        assert_eq!(std::fs::read_to_string(second).unwrap(), "two\n");
    }

    #[test]
    fn the_raw_probe_runs_only_when_ci_turns_it_on() {
        assert!(super::raw_probe_enabled(Some("1")));
        for off in [None, Some(""), Some("0"), Some("true"), Some("yes"), Some(" 1")] {
            assert!(!super::raw_probe_enabled(off), "{off:?}");
        }
        assert_eq!(super::RAW_PROBE_ENV, "QUIP_SELFTEST_RAW_PROBE", "the name windows.yml sets");
    }
}
