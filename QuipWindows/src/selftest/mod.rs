//! `Quip.exe --selftest` (spec 10.5): the Win32 cases run on the PC through
//! the real app code, and a redacted PASS/FAIL report written to
//! `%LOCALAPPDATA%\Quip\Logs\selftest-<time>.txt` for the owner to send back.
//!
//! `report` (format, exit code, redaction) is pure and Mac-tested; `win32`
//! holds the case registry and runs it.

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

#[cfg(test)]
mod tests {
    use super::*;

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
}
