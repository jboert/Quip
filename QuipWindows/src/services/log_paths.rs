//! Where the logs and settings live (spec 7, 8). One place to change, like
//! `QuipMac/Services/LogPaths.swift` and `QuipLinux/src/services/log_paths.rs`.
//!
//! - Windows: logs in `%LOCALAPPDATA%\Quip\Logs`, settings in `%APPDATA%\Quip`.
//! - Anywhere else (the Mac, where `--fake-platform` and the tests run): a
//!   folder under the system temp dir, so a dev run can never write into the
//!   Mac app's `~/Library/Logs/Quip/` (the Mac's `LogPathsTestIsolationTests`
//!   rule). Tests pass their own temp dirs and never use these defaults.

use std::path::{Path, PathBuf};

pub const WEBSOCKET_LOG: &str = "websocket.log";
pub const INJECTION_LOG: &str = "injection.log";
pub const PHONE_LOG: &str = "phone.log";
pub const LATENCY_LOG: &str = "latency.log";

/// The log folder and the four files in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogPaths {
    dir: PathBuf,
}

impl LogPaths {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// The default for this OS. `env` is passed in so the choice is testable.
    pub fn default_dir(env: &dyn Fn(&str) -> Option<String>) -> PathBuf {
        if cfg!(windows) {
            if let Some(local) = env("LOCALAPPDATA") {
                return Path::new(&local).join("Quip").join("Logs");
            }
        }
        std::env::temp_dir().join("quip-windows-dev").join("Logs")
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Best-effort: a missing folder only means log lines are dropped
    /// (`quip_log` never fails loudly).
    pub fn ensure_dir(&self) {
        let _ = std::fs::create_dir_all(&self.dir);
    }

    pub fn websocket(&self) -> PathBuf {
        self.dir.join(WEBSOCKET_LOG)
    }
    pub fn injection(&self) -> PathBuf {
        self.dir.join(INJECTION_LOG)
    }
    pub fn phone(&self) -> PathBuf {
        self.dir.join(PHONE_LOG)
    }
    pub fn latency(&self) -> PathBuf {
        self.dir.join(LATENCY_LOG)
    }
}

/// `%APPDATA%\Quip` on Windows (settings.toml, phone-prefs.json); a temp
/// folder elsewhere.
pub fn default_config_dir(env: &dyn Fn(&str) -> Option<String>) -> PathBuf {
    if cfg!(windows) {
        if let Some(roaming) = env("APPDATA") {
            return Path::new(&roaming).join("Quip");
        }
    }
    std::env::temp_dir().join("quip-windows-dev").join("config")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn files_live_in_the_dir() {
        let p = LogPaths::new("/x/Logs");
        assert_eq!(p.websocket(), Path::new("/x/Logs/websocket.log"));
        assert_eq!(p.injection(), Path::new("/x/Logs/injection.log"));
        assert_eq!(p.phone(), Path::new("/x/Logs/phone.log"));
        assert_eq!(p.latency(), Path::new("/x/Logs/latency.log"));
    }

    #[test]
    fn non_windows_default_never_points_at_the_mac_apps_logs() {
        let env = |k: &str| (k == "LOCALAPPDATA" || k == "APPDATA").then(|| "C:\\U\\AppData".to_string());
        let logs = LogPaths::default_dir(&env);
        let cfg = default_config_dir(&env);
        if cfg!(windows) {
            assert!(logs.ends_with(Path::new("Quip").join("Logs")));
        } else {
            assert!(logs.starts_with(std::env::temp_dir()));
            assert!(cfg.starts_with(std::env::temp_dir()));
            assert!(!logs.to_string_lossy().contains("Library/Logs/Quip"));
        }
    }

    #[test]
    fn missing_env_falls_back_to_temp() {
        let none = |_: &str| None;
        assert!(LogPaths::default_dir(&none).starts_with(std::env::temp_dir()));
        assert!(default_config_dir(&none).starts_with(std::env::temp_dir()));
    }
}
