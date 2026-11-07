//! `settings.toml` (spec 7): `%APPDATA%\Quip\settings.toml` on Windows.
//!
//! ```toml
//! pin = "12345678"
//! device_id = "<uuid>"
//! port = 8765
//! show_all_apps = false
//! enabled_windows = [ { exe = "C:\\...\\WindowsTerminal.exe", title = "..." } ]
//! disabled_windows = [ ... ]
//! pinned_windows = [ { exe = "...", title = "..." } ]   # oldest pin first
//! window_colors = [ { exe = "...", title = "...", color = "#4A90D9" } ]
//! ```
//!
//! Created on first run. A file that does not parse, or parses but carries an
//! unusable PIN or device id, is renamed to `settings.toml.bad` and a fresh
//! one is made (new PIN, new device id); the caller writes a `websocket.log`
//! line. A file that cannot be READ (locked by an antivirus scan or a sync
//! client, permissions) is not corrupt: the read is retried `READ_ATTEMPTS`
//! times, then loading fails loudly. It never mints a new PIN and device id
//! for a file that may be fine, which would unpair every phone.
//!
//! `disabled_windows` is an addition to the spec's list: terminals start
//! enabled, so "the user turned this terminal off" has to be stored too, or a
//! toggle-off would not survive a restart.
//!
//! `pinned_windows` and `window_colors` hold the phone's `set_pin` and
//! `set_color` choices under the same key (the Mac's `pinnedWindowIDs` and
//! `windowColorOverrides`, which it keys by window id). Both default to empty,
//! so a file written before they existed still loads.

use std::path::{Path, PathBuf};

use rand::Rng;
use serde::{Deserialize, Serialize};

use super::{device_id, pin_store};

pub const FILE_NAME: &str = "settings.toml";
pub const DEFAULT_PORT: u16 = 8765;
/// Reads of an existing file that fails with an I/O error.
pub const READ_ATTEMPTS: u32 = 3;
pub const READ_RETRY_DELAY: std::time::Duration = std::time::Duration::from_millis(50);

/// Best-effort stable key for a window across restarts (spec 5.1).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct WindowKey {
    pub exe: String,
    pub title: String,
}

/// One saved `set_color` choice: the window key and its `#RRGGBB`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WindowColorChoice {
    pub exe: String,
    pub title: String,
    pub color: String,
}

impl WindowColorChoice {
    pub fn key(&self) -> WindowKey {
        WindowKey { exe: self.exe.clone(), title: self.title.clone() }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Settings {
    pub pin: String,
    pub device_id: String,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default)]
    pub show_all_apps: bool,
    #[serde(default)]
    pub enabled_windows: Vec<WindowKey>,
    #[serde(default)]
    pub disabled_windows: Vec<WindowKey>,
    /// Oldest pin first: that is the pinned group's order after a restart.
    #[serde(default)]
    pub pinned_windows: Vec<WindowKey>,
    #[serde(default)]
    pub window_colors: Vec<WindowColorChoice>,
}

fn default_port() -> u16 {
    DEFAULT_PORT
}

impl Settings {
    pub fn fresh(rng: &mut impl Rng) -> Self {
        Settings {
            pin: pin_store::generate(rng),
            device_id: device_id::generate(),
            port: DEFAULT_PORT,
            show_all_apps: false,
            enabled_windows: vec![],
            disabled_windows: vec![],
            pinned_windows: vec![],
            window_colors: vec![],
        }
    }

    fn is_usable(&self) -> bool {
        pin_store::is_valid_stored(&self.pin) && device_id::is_valid(&self.device_id) && self.port != 0
    }

    /// Record the user's enable choice for `key`, replacing any earlier one.
    pub fn set_enabled_override(&mut self, key: WindowKey, enabled: bool) {
        self.enabled_windows.retain(|k| k != &key);
        self.disabled_windows.retain(|k| k != &key);
        if enabled {
            self.enabled_windows.push(key);
        } else {
            self.disabled_windows.push(key);
        }
    }

    /// Record a pin (appended: the newest pin is last) or remove one.
    pub fn set_pinned(&mut self, key: WindowKey, pinned: bool) {
        self.pinned_windows.retain(|k| k != &key);
        if pinned {
            self.pinned_windows.push(key);
        }
    }

    /// Record the color chosen for `key`, or clear it with `None`.
    pub fn set_color_override(&mut self, key: WindowKey, color: Option<String>) {
        self.window_colors.retain(|c| c.exe != key.exe || c.title != key.title);
        if let Some(color) = color {
            self.window_colors.push(WindowColorChoice { exe: key.exe, title: key.title, color });
        }
    }

    /// The stored choice for `key`, if the user made one.
    pub fn enabled_override(&self, key: &WindowKey) -> Option<bool> {
        if self.enabled_windows.contains(key) {
            Some(true)
        } else if self.disabled_windows.contains(key) {
            Some(false)
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoadOutcome {
    Created,
    Loaded,
    /// The old file was unusable and moved here.
    Recovered {
        bad_path: PathBuf,
        reason: String,
    },
}

/// Loading failed without touching the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettingsError {
    /// The file exists but every read failed.
    Unreadable { attempts: u32, error: String },
    /// A fresh file (first run or after quarantine) could not be written.
    NotSaved(String),
}

impl std::fmt::Display for SettingsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SettingsError::Unreadable { attempts, error } => {
                write!(f, "settings.toml could not be read after {attempts} attempts: {error}")
            }
            SettingsError::NotSaved(e) => write!(f, "settings.toml could not be written: {e}"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SettingsStore {
    path: PathBuf,
}

impl SettingsStore {
    pub fn in_dir(dir: &Path) -> Self {
        Self { path: dir.join(FILE_NAME) }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn bad_path(&self) -> PathBuf {
        let mut s = self.path.as_os_str().to_owned();
        s.push(".bad");
        PathBuf::from(s)
    }

    /// Blocks (file I/O and up to `READ_ATTEMPTS` sleeps): call it before
    /// the runtime starts or through `spawn_blocking`, never on a tokio worker.
    pub fn load_or_create(&self, rng: &mut impl Rng) -> Result<(Settings, LoadOutcome), SettingsError> {
        let mut attempt = 0;
        let text = loop {
            attempt += 1;
            match std::fs::read_to_string(&self.path) {
                Ok(t) => break Some(t),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => break None,
                Err(e) if attempt >= READ_ATTEMPTS => {
                    return Err(SettingsError::Unreadable { attempts: attempt, error: e.to_string() })
                }
                Err(_) => std::thread::sleep(READ_RETRY_DELAY),
            }
        };
        let outcome = match text {
            None => LoadOutcome::Created,
            Some(text) => match toml::from_str::<Settings>(&text) {
                Ok(s) if s.is_usable() => return Ok((s, LoadOutcome::Loaded)),
                Ok(_) => self.quarantine("invalid pin, device_id or port".to_string()),
                // The TOML error can quote the offending line, which may be the
                // PIN; keep only its first line, never the file content.
                Err(e) => self.quarantine(format!("does not parse: {}", e.message().lines().next().unwrap_or(""))),
            },
        };
        let fresh = Settings::fresh(rng);
        self.save(&fresh).map_err(|e| SettingsError::NotSaved(e.to_string()))?;
        Ok((fresh, outcome))
    }

    fn quarantine(&self, reason: String) -> LoadOutcome {
        let bad = self.bad_path();
        let _ = std::fs::remove_file(&bad);
        let _ = std::fs::rename(&self.path, &bad);
        LoadOutcome::Recovered { bad_path: bad, reason }
    }

    /// Write via a temp file + rename so a crash mid-write cannot leave a
    /// half file (which the next launch would quarantine, losing the PIN).
    pub fn save(&self, settings: &Settings) -> std::io::Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let text = toml::to_string(settings).map_err(std::io::Error::other)?;
        let mut tmp = self.path.as_os_str().to_owned();
        tmp.push(".tmp");
        let tmp = PathBuf::from(tmp);
        std::fs::write(&tmp, text)?;
        std::fs::rename(&tmp, &self.path)
    }
}

#[cfg(test)]
mod tests {
    //! Round-trip and corrupt-file cases (`PINStoreTests` shape, spec 10.3:
    //! "8 digits; corrupt settings -> .bad + new PIN").
    use super::*;
    use rand::rngs::StdRng;
    use rand::SeedableRng;

    fn rng() -> StdRng {
        StdRng::seed_from_u64(42)
    }

    #[test]
    fn first_run_creates_the_file_with_an_8_digit_pin() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::in_dir(dir.path());
        let (s, o) = store.load_or_create(&mut rng()).unwrap();
        assert_eq!(o, LoadOutcome::Created);
        assert_eq!(s.pin.len(), 8);
        assert!(device_id::is_valid(&s.device_id));
        assert_eq!(s.port, 8765);
        assert!(!s.show_all_apps);
        assert!(store.path().exists());
    }

    #[test]
    fn second_run_loads_the_same_pin_and_device_id() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::in_dir(dir.path());
        let (a, _) = store.load_or_create(&mut rng()).unwrap();
        let (b, o) = store.load_or_create(&mut StdRng::seed_from_u64(99)).unwrap();
        assert_eq!(o, LoadOutcome::Loaded);
        assert_eq!(a, b);
    }

    #[test]
    fn round_trip_overwrite() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::in_dir(dir.path());
        let (mut s, _) = store.load_or_create(&mut rng()).unwrap();
        s.pin = "11112222".into();
        s.show_all_apps = true;
        s.set_enabled_override(WindowKey { exe: "C:\\a.exe".into(), title: "t \"q\"".into() }, false);
        store.save(&s).unwrap();
        let (back, o) = store.load_or_create(&mut rng()).unwrap();
        assert_eq!(o, LoadOutcome::Loaded);
        assert_eq!(back, s);
    }

    #[test]
    fn corrupt_file_is_moved_to_bad_and_a_new_pin_is_made() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::in_dir(dir.path());
        std::fs::write(store.path(), "pin = \"12345678\"\nthis is not toml [[[").unwrap();
        let (s, o) = store.load_or_create(&mut rng()).unwrap();
        let LoadOutcome::Recovered { bad_path, reason } = o else { panic!("expected recovery") };
        assert_eq!(bad_path, store.bad_path());
        assert!(bad_path.ends_with("settings.toml.bad"));
        assert!(std::fs::read_to_string(&bad_path).unwrap().contains("not toml"));
        assert!(!reason.contains("12345678"), "the reason never quotes the file: {reason}");
        assert_eq!(s.pin.len(), 8);
        let (again, o2) = store.load_or_create(&mut rng()).unwrap();
        assert_eq!(o2, LoadOutcome::Loaded, "the fresh file was written");
        assert_eq!(again, s);
    }

    #[test]
    fn unusable_values_count_as_corrupt() {
        for body in [
            "pin = \"\"\ndevice_id = \"6BA7B810-9DAD-11D1-80B4-00C04FD430C8\"\n",
            "pin = \"12345678\"\ndevice_id = \"nope\"\n",
            "pin = \"12345678\"\ndevice_id = \"6BA7B810-9DAD-11D1-80B4-00C04FD430C8\"\nport = 0\n",
            "pin = \"12345678\"\n",
        ] {
            let dir = tempfile::tempdir().unwrap();
            let store = SettingsStore::in_dir(dir.path());
            std::fs::write(store.path(), body).unwrap();
            let (_, o) = store.load_or_create(&mut rng()).unwrap();
            assert!(matches!(o, LoadOutcome::Recovered { .. }), "{body}");
        }
    }

    #[test]
    fn a_previous_bad_file_is_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::in_dir(dir.path());
        std::fs::write(store.bad_path(), "old").unwrap();
        std::fs::write(store.path(), "[[[").unwrap();
        store.load_or_create(&mut rng()).unwrap();
        assert_eq!(std::fs::read_to_string(store.bad_path()).unwrap(), "[[[");
    }

    #[test]
    fn a_read_error_retries_then_fails_without_a_new_pin_or_quarantine() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::in_dir(dir.path());
        std::fs::create_dir(store.path()).unwrap(); // exists, but every read fails
        let t0 = std::time::Instant::now();
        let e = store.load_or_create(&mut rng()).unwrap_err();
        assert!(matches!(e, SettingsError::Unreadable { attempts: READ_ATTEMPTS, .. }), "{e:?}");
        assert!(t0.elapsed() >= READ_RETRY_DELAY * (READ_ATTEMPTS - 1), "it waited between attempts");
        assert!(store.path().is_dir(), "the file is left alone");
        assert!(!store.bad_path().exists(), "not quarantined");
        assert!(e.to_string().contains("could not be read after 3 attempts"));
    }

    #[cfg(unix)]
    #[test]
    fn a_fresh_file_that_cannot_be_written_is_an_error() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let ro = dir.path().join("ro");
        std::fs::create_dir(&ro).unwrap();
        std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o500)).unwrap();
        let r = SettingsStore::in_dir(&ro).load_or_create(&mut rng());
        std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(matches!(r, Err(SettingsError::NotSaved(_))), "{r:?}");
    }

    #[test]
    fn a_file_without_a_port_gets_8765() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::in_dir(dir.path());
        std::fs::write(store.path(), "pin = \"12345678\"\ndevice_id = \"6BA7B810-9DAD-11D1-80B4-00C04FD430C8\"\n")
            .unwrap();
        let (s, o) = store.load_or_create(&mut rng()).unwrap();
        assert_eq!(o, LoadOutcome::Loaded);
        assert_eq!(s.port, DEFAULT_PORT);
    }

    #[test]
    fn overrides_for_other_windows_are_kept() {
        let mut s = Settings::fresh(&mut rng());
        let a = WindowKey { exe: "a".into(), title: "1".into() };
        let b = WindowKey { exe: "b".into(), title: "2".into() };
        s.set_enabled_override(a.clone(), true);
        s.set_enabled_override(b.clone(), false);
        s.set_enabled_override(b.clone(), true);
        assert_eq!(s.enabled_override(&a), Some(true));
        assert_eq!(s.enabled_windows, vec![a, b]);
        assert!(s.disabled_windows.is_empty());
    }

    #[test]
    fn a_file_from_before_pins_and_colors_still_loads() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::in_dir(dir.path());
        std::fs::write(
            store.path(),
            "pin = \"12345678\"\ndevice_id = \"6BA7B810-9DAD-11D1-80B4-00C04FD430C8\"\nport = 8765\nshow_all_apps = false\n\
             enabled_windows = [ { exe = \"C:\\\\a.exe\", title = \"t\" } ]\ndisabled_windows = []\n",
        )
        .unwrap();
        let (s, o) = store.load_or_create(&mut rng()).unwrap();
        assert_eq!(o, LoadOutcome::Loaded, "not quarantined: the PIN survives");
        assert_eq!(s.pin, "12345678");
        assert_eq!(s.enabled_windows.len(), 1);
        assert!(s.pinned_windows.is_empty() && s.window_colors.is_empty());
    }

    #[test]
    fn pins_keep_their_order_and_colors_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::in_dir(dir.path());
        let (mut s, _) = store.load_or_create(&mut rng()).unwrap();
        let a = WindowKey { exe: "a".into(), title: "1".into() };
        let b = WindowKey { exe: "b".into(), title: "2".into() };
        s.set_pinned(a.clone(), true);
        s.set_pinned(b.clone(), true);
        s.set_pinned(a.clone(), true);
        assert_eq!(s.pinned_windows, vec![b.clone(), a.clone()], "a re-pin moves to the end");
        s.set_pinned(b.clone(), false);
        assert_eq!(s.pinned_windows, vec![a.clone()]);
        s.set_color_override(a.clone(), Some("#4A90D9".into()));
        s.set_color_override(a.clone(), Some("#FF6B6B".into()));
        s.set_color_override(b.clone(), Some("#7ED321".into()));
        s.set_color_override(b.clone(), None);
        assert_eq!(
            s.window_colors,
            vec![WindowColorChoice { exe: "a".into(), title: "1".into(), color: "#FF6B6B".into() }]
        );
        assert_eq!(s.window_colors[0].key(), a);
        store.save(&s).unwrap();
        let (back, o) = store.load_or_create(&mut rng()).unwrap();
        assert_eq!(o, LoadOutcome::Loaded);
        assert_eq!(back, s);
    }

    #[test]
    fn enabled_override_is_last_write_wins() {
        let mut s = Settings::fresh(&mut rng());
        let k = WindowKey { exe: "a".into(), title: "b".into() };
        assert_eq!(s.enabled_override(&k), None);
        s.set_enabled_override(k.clone(), false);
        assert_eq!(s.enabled_override(&k), Some(false));
        s.set_enabled_override(k.clone(), true);
        assert_eq!(s.enabled_override(&k), Some(true));
        assert_eq!(s.enabled_windows.len() + s.disabled_windows.len(), 1);
    }
}
