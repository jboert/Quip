use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

use crate::protocol::messages::PreferencesSnapshot;

/// Persisted phone-prefs registry. Mirrors Mac's UserDefaults-keyed
/// per-deviceID PreferencesSnapshot stash.
///
/// On disk: a single JSON file at `~/.config/quip/phone-prefs.json` with
/// shape `{ "deviceID": PreferencesSnapshot, ... }`. On every snapshot we
/// rewrite the whole file — the registry is small (one entry per phone the
/// user has paired) and this avoids any partial-write headaches.
pub struct PreferencesStore {
    path: PathBuf,
    inner: Mutex<HashMap<String, PreferencesSnapshot>>,
}

impl PreferencesStore {
    pub fn default_production() -> Self {
        let path = directories::ProjectDirs::from("dev", "quip", "quip")
            .map(|p| p.config_dir().join("phone-prefs.json"))
            .unwrap_or_else(|| PathBuf::from("/tmp/quip-phone-prefs.json"));
        let inner = Self::load_from_disk(&path).unwrap_or_default();
        Self {
            path,
            inner: Mutex::new(inner),
        }
    }

    pub fn at_path(path: PathBuf) -> Self {
        let inner = Self::load_from_disk(&path).unwrap_or_default();
        Self {
            path,
            inner: Mutex::new(inner),
        }
    }

    fn load_from_disk(path: &PathBuf) -> Option<HashMap<String, PreferencesSnapshot>> {
        let bytes = fs::read(path).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    fn persist(&self, map: &HashMap<String, PreferencesSnapshot>) {
        if let Some(parent) = self.path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_vec_pretty(map) {
            // Best-effort. Failure here just means a reinstall won't restore;
            // not a hard error.
            let _ = fs::write(&self.path, json);
        }
    }

    /// Replace the snapshot for a given device. Persists synchronously.
    pub fn put(&self, device_id: String, snapshot: PreferencesSnapshot) {
        let mut map = self.inner.lock().expect("preferences_store poisoned");
        map.insert(device_id, snapshot);
        self.persist(&map);
    }

    /// Get the snapshot for a device. Returns an empty snapshot when none
    /// is stored — matches Mac's behavior of replying with an empty
    /// `PreferenceRestoreMessage` for first-time devices.
    pub fn get(&self, device_id: &str) -> PreferencesSnapshot {
        self.inner
            .lock()
            .expect("preferences_store poisoned")
            .get(device_id)
            .cloned()
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn temp_path() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("quip-prefs-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("prefs.json")
    }

    #[test]
    fn put_then_get_round_trips() {
        let store = PreferencesStore::at_path(temp_path());
        let snap = PreferencesSnapshot {
            content_zoom_level: Some(2),
            push_paused: Some(true),
            ..Default::default()
        };
        store.put("dev-A".into(), snap.clone());
        assert_eq!(store.get("dev-A"), snap);
    }

    #[test]
    fn unknown_device_returns_empty_snapshot() {
        let store = PreferencesStore::at_path(temp_path());
        assert_eq!(store.get("never-seen"), PreferencesSnapshot::default());
    }

    #[test]
    fn second_store_at_same_path_loads_persisted_data() {
        let path = temp_path();
        {
            let s = PreferencesStore::at_path(path.clone());
            s.put(
                "dev-B".into(),
                PreferencesSnapshot {
                    tts_enabled: Some(true),
                    ..Default::default()
                },
            );
        }
        let reopened = PreferencesStore::at_path(path);
        assert_eq!(reopened.get("dev-B").tts_enabled, Some(true));
    }
}
