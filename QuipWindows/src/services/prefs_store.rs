//! The phone's preference backup (spec 3.3): `preferences_snapshot` is kept
//! as-is per `deviceID` and handed back on `preferences_request`, so a phone
//! paired only with this PC still gets its settings back after a reinstall.
//! File: `%APPDATA%\Quip\phone-prefs.json` (`{ "<deviceID>": { …prefs… } }`).
//!
//! `NoBackup` is the `--fake-platform` mode (fake-mac's rule): nothing is
//! stored and every request gets the empty "no backup" reply, because a
//! restore carrying paired backends would make a QA phone dial them.
//!
//! A file that cannot be read as a JSON object is never overwritten: it is
//! renamed to `phone-prefs.json.bad` (the caller logs the line), so another
//! phone's backup in it can still be recovered by hand. A file that exists
//! but cannot be read at all (permissions, a locked file) is left alone and
//! the store fails, rather than replacing it with one phone's snapshot.
//!
//! Every method blocks on the disk: the router calls them through
//! `spawn_blocking`, never on a tokio worker.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{Map, Value};

pub enum PrefsStore {
    File { path: PathBuf, lock: Mutex<()> },
    NoBackup,
}

/// What `store` did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stored {
    /// `false` in no-backup mode.
    pub stored: bool,
    /// A corrupt file was moved here first.
    pub quarantined: Option<PathBuf>,
}

/// What `restore` found.
#[derive(Debug, Clone, PartialEq)]
pub struct Restored {
    pub prefs: Value,
    pub quarantined: Option<PathBuf>,
    /// The file exists but could not be read; `prefs` is then `{}`.
    pub read_error: Option<String>,
}

enum Read {
    Ok(Map<String, Value>),
    Missing,
    Corrupt,
    Unreadable(String),
}

impl PrefsStore {
    pub fn file(path: PathBuf) -> Self {
        PrefsStore::File { path, lock: Mutex::new(()) }
    }

    pub fn bad_path(path: &Path) -> PathBuf {
        let mut s = path.as_os_str().to_owned();
        s.push(".bad");
        PathBuf::from(s)
    }

    fn read_all(path: &Path) -> Read {
        match std::fs::read_to_string(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Read::Missing,
            Err(e) => Read::Unreadable(e.to_string()),
            Ok(t) => match serde_json::from_str::<Value>(&t) {
                Ok(Value::Object(m)) => Read::Ok(m),
                _ => Read::Corrupt,
            },
        }
    }

    /// Move a corrupt file aside, replacing an older `.bad`.
    fn quarantine(path: &Path) -> Result<PathBuf, String> {
        let bad = Self::bad_path(path);
        let _ = std::fs::remove_file(&bad);
        std::fs::rename(path, &bad).map_err(|e| format!("corrupt file could not be moved to .bad: {e}"))?;
        Ok(bad)
    }

    /// Store `prefs` for `device_id`. `Err` carries a reason for the log (the
    /// phone believes it is backed up, so a failed store must be loud there).
    pub fn store(&self, device_id: &str, prefs: Map<String, Value>) -> Result<Stored, String> {
        match self {
            PrefsStore::NoBackup => Ok(Stored { stored: false, quarantined: None }),
            PrefsStore::File { path, lock } => {
                let _g = lock.lock().unwrap_or_else(|p| p.into_inner());
                let mut quarantined = None;
                let mut all = match Self::read_all(path) {
                    Read::Ok(m) => m,
                    Read::Missing => Map::new(),
                    Read::Corrupt => {
                        quarantined = Some(Self::quarantine(path)?);
                        Map::new()
                    }
                    Read::Unreadable(e) => return Err(format!("existing file could not be read ({e}); left as is")),
                };
                all.insert(device_id.to_string(), Value::Object(prefs));
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                }
                let text = serde_json::to_string(&Value::Object(all)).map_err(|e| e.to_string())?;
                let mut tmp = path.as_os_str().to_owned();
                tmp.push(".tmp");
                std::fs::write(&tmp, text).map_err(|e| e.to_string())?;
                std::fs::rename(&tmp, path).map_err(|e| e.to_string())?;
                Ok(Stored { stored: true, quarantined })
            }
        }
    }

    /// The stored snapshot, or `{}` ("no backup").
    pub fn restore(&self, device_id: &str) -> Restored {
        let empty = || Value::Object(Map::new());
        match self {
            PrefsStore::NoBackup => Restored { prefs: empty(), quarantined: None, read_error: None },
            PrefsStore::File { path, lock } => {
                let _g = lock.lock().unwrap_or_else(|p| p.into_inner());
                match Self::read_all(path) {
                    Read::Ok(mut m) => Restored {
                        prefs: m.remove(device_id).unwrap_or_else(empty),
                        quarantined: None,
                        read_error: None,
                    },
                    Read::Missing => Restored { prefs: empty(), quarantined: None, read_error: None },
                    Read::Corrupt => match Self::quarantine(path) {
                        Ok(bad) => Restored { prefs: empty(), quarantined: Some(bad), read_error: None },
                        Err(e) => Restored { prefs: empty(), quarantined: None, read_error: Some(e) },
                    },
                    Read::Unreadable(e) => Restored { prefs: empty(), quarantined: None, read_error: Some(e) },
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn obj(v: Value) -> Map<String, Value> {
        match v {
            Value::Object(m) => m,
            _ => unreachable!(),
        }
    }

    #[test]
    fn stores_per_device_and_returns_as_is() {
        let dir = tempfile::tempdir().unwrap();
        let s = PrefsStore::file(dir.path().join("phone-prefs.json"));
        s.store("A", obj(json!({"pushSound": true, "future": {"x": [1]}}))).unwrap();
        s.store("B", obj(json!({"pushSound": false}))).unwrap();
        assert_eq!(s.restore("A").prefs, json!({"pushSound": true, "future": {"x": [1]}}));
        assert_eq!(s.restore("B").prefs, json!({"pushSound": false}));
        assert_eq!(s.restore("C").prefs, json!({}));
    }

    #[test]
    fn a_newer_snapshot_replaces_the_older() {
        let dir = tempfile::tempdir().unwrap();
        let s = PrefsStore::file(dir.path().join("p.json"));
        s.store("A", obj(json!({"a": 1}))).unwrap();
        s.store("A", obj(json!({"b": 2}))).unwrap();
        assert_eq!(s.restore("A").prefs, json!({"b": 2}));
    }

    #[test]
    fn a_corrupt_file_is_moved_to_bad_on_store_never_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("p.json");
        std::fs::write(&p, "{\"OTHER\": {\"x\": 1}, oops").unwrap();
        let s = PrefsStore::file(p.clone());
        let r = s.store("A", obj(json!({"a": 1}))).unwrap();
        assert_eq!(r, Stored { stored: true, quarantined: Some(PrefsStore::bad_path(&p)) });
        assert_eq!(std::fs::read_to_string(PrefsStore::bad_path(&p)).unwrap(), "{\"OTHER\": {\"x\": 1}, oops");
        assert_eq!(s.restore("A").prefs, json!({"a": 1}));
    }

    #[test]
    fn a_corrupt_file_is_moved_to_bad_on_restore() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("p.json");
        std::fs::write(&p, "[1,2]").unwrap(); // JSON, but not the object we write
        let s = PrefsStore::file(p.clone());
        let r = s.restore("A");
        assert_eq!(r.prefs, json!({}));
        assert_eq!(r.quarantined, Some(PrefsStore::bad_path(&p)));
        assert!(!p.exists());
        assert_eq!(std::fs::read_to_string(PrefsStore::bad_path(&p)).unwrap(), "[1,2]");
    }

    #[test]
    fn an_unreadable_file_is_left_alone_and_the_store_fails() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("p.json");
        std::fs::create_dir(&p).unwrap(); // exists, cannot be read as a file
        let s = PrefsStore::file(p.clone());
        let e = s.store("A", obj(json!({"a": 1}))).unwrap_err();
        assert!(e.contains("could not be read"), "{e}");
        assert!(p.is_dir() && !PrefsStore::bad_path(&p).exists());
        let r = s.restore("A");
        assert!(r.read_error.is_some() && r.quarantined.is_none());
    }

    #[test]
    fn no_backup_mode_stores_nothing() {
        let s = PrefsStore::NoBackup;
        assert_eq!(s.store("A", obj(json!({"a": 1}))), Ok(Stored { stored: false, quarantined: None }));
        assert_eq!(s.restore("A").prefs, json!({}));
    }
}
