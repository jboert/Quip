//! The single write path for every log file (`QuipMac/Services/QuipLog.swift`).
//!
//! Contract carried over from the Mac, where a full disk aborted the app twice
//! in one morning through a raising write API (`99927a4`):
//! - append-only, one line per event;
//! - a write failure (missing folder, read-only folder, full disk) is dropped
//!   silently, never a panic and never an error to the caller;
//! - a file past `MAX_LOG_BYTES` is rolled to `<name>.1` (one old copy) before
//!   the next write (`LogPaths.rotateIfNeeded`).

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Spec 8: 10 MB per file. The Mac uses 16 MiB (`LogPaths.maxLogBytes`); the
/// Windows spec chose 10 MB.
pub const MAX_LOG_BYTES: u64 = 10 * 1024 * 1024;

/// Serializes check-rotate-append so two writers cannot interleave a line or
/// both rotate (the Mac's `writeLock`).
static WRITE_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Info,
    Warn,
    Error,
}

impl Severity {
    pub fn as_str(self) -> &'static str {
        match self {
            Severity::Info => "INFO",
            Severity::Warn => "WARN",
            Severity::Error => "ERROR",
        }
    }
}

/// Line breaks (CR, LF and the Unicode ones) become spaces, so a value from
/// the phone (a quick-action name, a window id) can never start a forged log
/// line of its own.
pub fn flatten(field: &str) -> std::borrow::Cow<'_, str> {
    let is_break = |c: char| matches!(c, '\r' | '\n' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}');
    if field.contains(is_break) {
        std::borrow::Cow::Owned(field.chars().map(|c| if is_break(c) { ' ' } else { c }).collect())
    } else {
        std::borrow::Cow::Borrowed(field)
    }
}

/// `QuipLog.line`: `[<iso8601>] [<SEV>] [<subsystem>] <message>\n`, every
/// field flattened to one line.
pub fn line(severity: Severity, subsystem: &str, message: &str, unix_seconds: f64) -> String {
    format!(
        "[{}] [{}] [{}] {}\n",
        super::clock::iso8601(unix_seconds),
        severity.as_str(),
        flatten(subsystem),
        flatten(message)
    )
}

/// `<path>.1`.
pub fn rolled_path(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(".1");
    PathBuf::from(s)
}

/// Roll `path` to `<path>.1` when it is larger than `max_bytes`, replacing any
/// previous `.1`. True when a rotation happened. Failures are swallowed: the
/// file then simply keeps growing.
pub fn rotate_if_needed(path: &Path, max_bytes: u64) -> bool {
    let Ok(meta) = std::fs::metadata(path) else { return false };
    if meta.len() <= max_bytes {
        return false;
    }
    let rolled = rolled_path(path);
    let _ = std::fs::remove_file(&rolled);
    std::fs::rename(path, &rolled).is_ok()
}

/// Append raw text with the never-fail contract.
pub fn append_with_cap(path: &Path, text: &str, max_bytes: u64) {
    let _guard = WRITE_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    rotate_if_needed(path, max_bytes);
    let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) else { return };
    let _ = f.write_all(text.as_bytes());
}

pub fn append(path: &Path, text: &str) {
    append_with_cap(path, text, MAX_LOG_BYTES);
}

pub fn write(path: &Path, severity: Severity, subsystem: &str, message: &str, unix_seconds: f64) {
    append(path, &line(severity, subsystem, message, unix_seconds));
}

#[cfg(test)]
mod tests {
    //! `QuipMac/Tests/QuipLogTests.swift` and `LogRotationTests.swift`.
    #![allow(non_snake_case)]
    use super::*;

    #[test]
    fn test_line_tagsSeverityAndSubsystem() {
        let l = line(Severity::Error, "ws", "socket died", 0.0);
        assert!(l.contains("[ERROR]"));
        assert!(l.contains("[ws]"));
        assert!(l.contains("socket died"));
        assert!(l.ends_with('\n'));
        assert!(l.starts_with("[1970-01-01T00:00:00Z] "));
    }

    #[test]
    fn line_breaks_in_any_field_never_make_a_second_line() {
        let l = line(
            Severity::Info,
            "w\ns",
            "quick_action evil\r\n[1970-01-01T00:00:00Z] [ERROR] [ws] forged\u{2028}x",
            0.0,
        );
        assert_eq!(l.matches('\n').count(), 1, "{l:?}");
        assert!(l.ends_with('\n'));
        assert!(!l.contains('\r') && !l.contains('\u{2028}'));
        assert!(l.contains("[w s]"));
        assert!(l.contains("evil  [1970"));
        assert_eq!(flatten("plain"), "plain");
        assert_eq!(flatten("a\u{85}b\u{0B}c\u{0C}d\u{2029}"), "a b c d ");
    }

    #[test]
    fn test_line_infoAndWarnAreDistinguishable() {
        let info = line(Severity::Info, "ws", "probe closed", 0.0);
        let warn = line(Severity::Warn, "ws", "retrying", 0.0);
        assert!(info.contains("[INFO]"));
        assert!(warn.contains("[WARN]"));
        assert!(!info.contains("[ERROR]"));
    }

    #[test]
    fn test_write_appendsAndCreatesFile() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("q.log");
        write(&p, Severity::Info, "test", "first", 0.0);
        write(&p, Severity::Error, "test", "second", 0.0);
        let c = std::fs::read_to_string(&p).unwrap();
        assert!(c.contains("first") && c.contains("second"));
        assert_eq!(c.lines().count(), 2);
    }

    #[test]
    fn test_write_toNonexistentDirectory_doesNotCrashOrThrow() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("no-such-dir").join("quip.log");
        write(&p, Severity::Error, "test", "swallowed", 0.0);
        assert!(!p.exists());
    }

    #[cfg(unix)]
    #[test]
    fn read_only_directory_never_panics() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let ro = dir.path().join("ro");
        std::fs::create_dir(&ro).unwrap();
        std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o500)).unwrap();
        let p = ro.join("quip.log");
        write(&p, Severity::Error, "test", "swallowed", 0.0);
        std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    /// The full-disk case: on Linux/macOS `/dev/full` style devices are not
    /// portable, so a write to a path that is a DIRECTORY stands in for "the
    /// OS refused the write after open" — the call must return normally.
    #[test]
    fn write_failure_after_open_is_swallowed() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), Severity::Error, "test", &"x".repeat(50_000), 0.0);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn full_disk_never_panics() {
        append(Path::new("/dev/full"), &"x".repeat(50_000));
    }

    #[test]
    fn test_rotateIfNeeded_leavesSmallFileAlone() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("small.log");
        std::fs::write(&p, "x".repeat(100)).unwrap();
        assert!(!rotate_if_needed(&p, 1024));
        assert!(p.exists());
        assert!(!rolled_path(&p).exists());
    }

    #[test]
    fn test_rotateIfNeeded_movesOversizedFileToDotOne() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("big.log");
        std::fs::write(&p, "x".repeat(5000)).unwrap();
        assert!(rotate_if_needed(&p, 1024));
        assert!(!p.exists());
        assert!(rolled_path(&p).exists());
    }

    #[test]
    fn test_rotateIfNeeded_overwritesPreviousGeneration() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("big.log");
        std::fs::write(&p, "a".repeat(5000)).unwrap();
        assert!(rotate_if_needed(&p, 1024));
        std::fs::write(&p, "b".repeat(5000)).unwrap();
        assert!(rotate_if_needed(&p, 1024));
        assert!(!dir.path().join("big.log.2").exists());
        let rolled = std::fs::read_to_string(rolled_path(&p)).unwrap();
        assert!(rolled.starts_with('b'));
    }

    #[test]
    fn test_rotateIfNeeded_missingFileIsNotAnError() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!rotate_if_needed(&dir.path().join("absent.log"), 1024));
    }

    #[test]
    fn exactly_at_cap_is_not_rotated() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("edge.log");
        std::fs::write(&p, "x".repeat(1024)).unwrap();
        assert!(!rotate_if_needed(&p, 1024));
        std::fs::write(&p, "x".repeat(1025)).unwrap();
        assert!(rotate_if_needed(&p, 1024));
    }

    #[test]
    fn append_rotates_at_the_cap_then_starts_fresh() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("r.log");
        append_with_cap(&p, &"a".repeat(2000), 1024);
        append_with_cap(&p, "next\n", 1024);
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "next\n");
        assert_eq!(std::fs::read_to_string(rolled_path(&p)).unwrap().len(), 2000);
    }

    #[test]
    fn ten_megabyte_cap() {
        assert_eq!(MAX_LOG_BYTES, 10_485_760);
    }
}
