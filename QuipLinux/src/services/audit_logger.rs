use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::SystemTime;

const MAX_FILE_SIZE: u64 = 10 * 1024 * 1024; // 10MB

/// Returns the audit log path: ~/.local/share/quip/audit.log
fn log_path() -> PathBuf {
    let base = std::env::var("XDG_DATA_HOME").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        format!("{home}/.local/share")
    });
    PathBuf::from(base).join("quip").join("audit.log")
}

fn rotated_path() -> PathBuf {
    let mut p = log_path();
    p.set_extension("log.1");
    p
}

/// Format a SystemTime as ISO8601-ish UTC timestamp (no chrono dependency).
fn format_timestamp(t: SystemTime) -> String {
    let dur = t.duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default();
    let secs = dur.as_secs();
    // Break into date/time components
    let days = secs / 86400;
    let time_secs = secs % 86400;
    let hours = time_secs / 3600;
    let minutes = (time_secs % 3600) / 60;
    let seconds = time_secs % 60;

    // Compute year/month/day from days since epoch (1970-01-01)
    let (year, month, day) = days_to_ymd(days);
    format!("{year:04}-{month:02}-{day:02}T{hours:02}:{minutes:02}:{seconds:02}Z")
}

fn days_to_ymd(mut days: u64) -> (u64, u64, u64) {
    // Civil calendar algorithm
    let mut year = 1970u64;
    loop {
        let days_in_year = if is_leap(year) { 366 } else { 365 };
        if days < days_in_year {
            break;
        }
        days -= days_in_year;
        year += 1;
    }
    let leap = is_leap(year);
    let month_days: [u64; 12] = [
        31,
        if leap { 29 } else { 28 },
        31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
    ];
    let mut month = 1u64;
    for &md in &month_days {
        if days < md {
            break;
        }
        days -= md;
        month += 1;
    }
    (year, month, days + 1)
}

fn is_leap(y: u64) -> bool {
    y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
}

fn prepare_log_file(path: &PathBuf) {
    let dir = path.parent().unwrap();
    if !dir.exists() {
        if let Err(e) = fs::create_dir_all(dir) {
            tracing::warn!("Failed to create audit log dir: {e}");
            return;
        }
        let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
    }
    if !path.exists() {
        if let Ok(f) = File::create(path) {
            let _ = f.set_permissions(fs::Permissions::from_mode(0o600));
        }
    }
}

fn rotate_if_needed(path: &PathBuf) {
    let size = fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    if size > MAX_FILE_SIZE {
        let rotated = rotated_path();
        let _ = fs::remove_file(&rotated);
        let _ = fs::rename(path, &rotated);
        if let Ok(f) = File::create(path) {
            let _ = f.set_permissions(fs::Permissions::from_mode(0o600));
        }
    }
}

fn write_entry(entry: &str) {
    let path = log_path();
    prepare_log_file(&path);
    rotate_if_needed(&path);

    if let Ok(mut file) = OpenOptions::new().append(true).open(&path) {
        let _ = file.write_all(entry.as_bytes());
    }
}

/// Background audit logger. Clone and call `log()` from any thread.
#[derive(Clone)]
pub struct AuditLogger {
    tx: mpsc::Sender<String>,
}

impl AuditLogger {
    /// Create a new AuditLogger with a background writer thread.
    pub fn new() -> Self {
        let (tx, rx) = mpsc::channel::<String>();
        std::thread::Builder::new()
            .name("audit-logger".into())
            .spawn(move || {
                while let Ok(entry) = rx.recv() {
                    write_entry(&entry);
                }
            })
            .expect("failed to spawn audit logger thread");
        Self { tx }
    }

    /// Log a remote command. Non-blocking — entry is queued to background thread.
    pub fn log(&self, message_type: &str, client_identifier: &str, text_content: &str) {
        let timestamp = format_timestamp(SystemTime::now());
        let truncated: String = text_content.chars().take(200).collect();
        let entry = format!(
            "[{timestamp}] client={client_identifier} type={message_type} text={truncated}\n"
        );
        let _ = self.tx.send(entry);
    }
}
