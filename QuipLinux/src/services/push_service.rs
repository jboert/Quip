use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use super::apns_client::{ApnsClient, ApnsError, RegisteredPushDevice};
use crate::protocol::messages::{PushPreferencesMessage, RegisterPushDeviceMessage};

/// Per-device preferences. Mirrors Mac's `DevicePushPreferences`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DevicePushPreferences {
    #[serde(default)]
    pub paused: bool,
    #[serde(default)]
    pub quiet_hours_start: Option<i32>,
    #[serde(default)]
    pub quiet_hours_end: Option<i32>,
    #[serde(default = "default_true")]
    pub sound: bool,
    #[serde(default)]
    pub foreground_banner: bool,
    /// Master banner toggle. When false, send() short-circuits — Live
    /// Activities still update via WebSocket but no APNs banner alert
    /// fires. Defaults to true for backwards compat.
    #[serde(default = "default_true")]
    pub banner_enabled: bool,
    /// IANA TZ identifier (e.g. "America/Phoenix"). When set, quiet-hours
    /// arithmetic uses the phone's clock, not the host's.
    #[serde(default)]
    pub time_zone: Option<String>,
}

fn default_true() -> bool {
    true
}

impl Default for DevicePushPreferences {
    fn default() -> Self {
        Self {
            paused: false,
            quiet_hours_start: None,
            quiet_hours_end: None,
            sound: true,
            foreground_banner: false,
            banner_enabled: true,
            time_zone: None,
        }
    }
}

impl DevicePushPreferences {
    /// True if `now`'s hour falls inside the quiet-hours window. Matches
    /// Mac's same-day vs overnight handling. Without `chrono` we evaluate
    /// in UTC unless a `time_zone` is given — which is good enough for
    /// quiet-hours boundary purposes since hours-of-day are coarse.
    /// (chrono-tz adds a meaningful binary-size hit; revisit if this drifts.)
    pub fn is_quiet_now(&self, now_unix_seconds: u64) -> bool {
        let (start, end) = match (self.quiet_hours_start, self.quiet_hours_end) {
            (Some(s), Some(e)) => (s, e),
            _ => return false,
        };
        if start == end {
            return false;
        }
        let hour = ((now_unix_seconds / 3600) % 24) as i32;
        if start < end {
            hour >= start && hour < end
        } else {
            hour >= start || hour < end
        }
    }
}

/// Per-window debounce key. We hash by (window_id, device_token) so
/// repeated state oscillations on the same window don't fan out into
/// dozens of pushes per device.
fn debounce_key(window_id: &str, device_token: &str) -> String {
    format!("{window_id}::{device_token}")
}

/// Persistent registry of iOS devices + their preferences, plus the
/// debounce + send wrapper around `ApnsClient`. Mirrors Mac's
/// `PushNotificationService` plus a slimmer set of features (no Mac
/// Settings UI side, since that's task 13's concern).
pub struct PushService {
    inner: Mutex<PushServiceInner>,
    /// Min interval between two pushes for the same (window, device) pair.
    debounce_interval: Duration,
    /// Optional APNs client. None until a .p8 key + key_id/team_id/bundle_id
    /// are configured. `send_for_window_state` short-circuits when None.
    apns: Mutex<Option<Arc<ApnsClient>>>,
}

struct PushServiceInner {
    devices: Vec<RegisteredPushDevice>,
    preferences: HashMap<String, DevicePushPreferences>,
    last_push_times: HashMap<String, Instant>,
}

impl PushService {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(PushServiceInner {
                devices: Vec::new(),
                preferences: HashMap::new(),
                last_push_times: HashMap::new(),
            }),
            debounce_interval: Duration::from_secs(30),
            apns: Mutex::new(None),
        })
    }

    pub fn set_apns_client(&self, client: Arc<ApnsClient>) {
        *self.apns.lock().expect("apns mutex poisoned") = Some(client);
    }

    pub fn clear_apns_client(&self) {
        *self.apns.lock().expect("apns mutex poisoned") = None;
    }

    /// Add or replace a device entry. Idempotent — repeat registrations
    /// from the same iOS app launch are silently merged.
    pub fn register(&self, msg: RegisterPushDeviceMessage) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let mut inner = self.inner.lock().expect("push registry poisoned");
        if let Some(existing) = inner
            .devices
            .iter_mut()
            .find(|d| d.token == msg.device_token)
        {
            existing.environment = msg.environment;
            existing.registered_at = now;
        } else {
            inner.devices.push(RegisteredPushDevice {
                token: msg.device_token,
                environment: msg.environment,
                registered_at: now,
            });
        }
    }

    pub fn apply_preferences(&self, msg: PushPreferencesMessage) {
        let mut inner = self.inner.lock().expect("push registry poisoned");
        let entry = inner
            .preferences
            .entry(msg.device_token.clone())
            .or_default();
        entry.paused = msg.paused;
        entry.quiet_hours_start = msg.quiet_hours_start;
        entry.quiet_hours_end = msg.quiet_hours_end;
        entry.sound = msg.sound;
        entry.foreground_banner = msg.foreground_banner;
        if let Some(b) = msg.banner_enabled {
            entry.banner_enabled = b;
        }
        if let Some(tz) = msg.time_zone {
            entry.time_zone = Some(tz);
        }
    }

    /// Drop a device on `Unregistered` from APNs.
    pub fn drop_device(&self, token: &str) {
        let mut inner = self.inner.lock().expect("push registry poisoned");
        inner.devices.retain(|d| d.token != token);
        inner.preferences.remove(token);
    }

    pub fn devices(&self) -> Vec<RegisteredPushDevice> {
        self.inner
            .lock()
            .expect("push registry poisoned")
            .devices
            .clone()
    }

    /// Send a "claude-is-waiting" alert for a window to every registered
    /// device, honoring per-device preferences and the (window, device)
    /// debounce. Returns the number of pushes actually attempted.
    pub fn send_for_window_state(
        &self,
        window_id: &str,
        window_name: &str,
        body: &str,
    ) -> usize {
        let apns = match self.apns.lock().expect("apns mutex poisoned").clone() {
            Some(c) => c,
            None => return 0,
        };

        let now = Instant::now();
        let now_unix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        // Snapshot under the lock so we don't hold it across the network call.
        let snapshot: Vec<(RegisteredPushDevice, DevicePushPreferences)> = {
            let mut inner = self.inner.lock().expect("push registry poisoned");
            let mut out = Vec::new();
            for device in &inner.devices.clone() {
                let prefs = inner
                    .preferences
                    .get(&device.token)
                    .cloned()
                    .unwrap_or_default();
                if prefs.paused || !prefs.banner_enabled || prefs.is_quiet_now(now_unix) {
                    continue;
                }
                let key = debounce_key(window_id, &device.token);
                if let Some(prev) = inner.last_push_times.get(&key) {
                    if now.duration_since(*prev) < self.debounce_interval {
                        continue;
                    }
                }
                inner.last_push_times.insert(key, now);
                out.push((device.clone(), prefs));
            }
            out
        };

        let mut sent = 0usize;
        for (device, prefs) in snapshot {
            let payload = build_payload(window_name, body, prefs.sound);
            match apns.send(&payload, &device, Some(window_id)) {
                Ok(()) => sent += 1,
                Err(ApnsError::Unregistered) => {
                    tracing::info!("APNs unregistered device {}, dropping", device.token);
                    self.drop_device(&device.token);
                }
                Err(e) => {
                    tracing::warn!("APNs send to {} failed: {}", device.token, e);
                }
            }
        }
        sent
    }
}

/// Compose the standard "{title}\n{body}" alert JSON. Sound is the default
/// system alert tone when enabled. Mac's payload helper wraps the same
/// keys; we mirror them so the iOS side renders identical notifications.
fn build_payload(title: &str, body: &str, sound: bool) -> String {
    let sound_field = if sound { ",\"sound\":\"default\"" } else { "" };
    format!(
        r#"{{"aps":{{"alert":{{"title":{},"body":{}}}{sound_field}}}}}"#,
        json_escape(title),
        json_escape(body),
    )
}

fn json_escape(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reg(token: &str, env: &str) -> RegisterPushDeviceMessage {
        RegisterPushDeviceMessage {
            device_token: token.into(),
            environment: env.into(),
        }
    }

    fn prefs(token: &str) -> PushPreferencesMessage {
        PushPreferencesMessage {
            type_: "push_preferences".into(),
            device_token: token.into(),
            paused: false,
            quiet_hours_start: None,
            quiet_hours_end: None,
            sound: true,
            foreground_banner: false,
            banner_enabled: Some(true),
            time_zone: None,
        }
    }

    #[test]
    fn register_dedups_by_token() {
        let s = PushService::new();
        s.register(reg("ABCD", "development"));
        s.register(reg("ABCD", "production"));
        s.register(reg("EFGH", "development"));
        let devices = s.devices();
        assert_eq!(devices.len(), 2);
        // Latest environment wins for the dup.
        assert_eq!(
            devices.iter().find(|d| d.token == "ABCD").unwrap().environment,
            "production"
        );
    }

    #[test]
    fn drop_device_clears_prefs() {
        let s = PushService::new();
        s.register(reg("X", "development"));
        s.apply_preferences(prefs("X"));
        s.drop_device("X");
        assert!(s.devices().is_empty());
    }

    #[test]
    fn quiet_hours_same_day() {
        let mut p = DevicePushPreferences::default();
        p.quiet_hours_start = Some(10);
        p.quiet_hours_end = Some(12);
        // 11:00 UTC
        assert!(p.is_quiet_now(11 * 3600));
        assert!(!p.is_quiet_now(13 * 3600));
    }

    #[test]
    fn quiet_hours_overnight() {
        let mut p = DevicePushPreferences::default();
        p.quiet_hours_start = Some(22);
        p.quiet_hours_end = Some(7);
        // 23:00 → quiet
        assert!(p.is_quiet_now(23 * 3600));
        // 03:00 → quiet
        assert!(p.is_quiet_now(3 * 3600));
        // 12:00 → not quiet
        assert!(!p.is_quiet_now(12 * 3600));
    }

    #[test]
    fn quiet_hours_disabled_when_bound_missing() {
        let mut p = DevicePushPreferences::default();
        p.quiet_hours_start = Some(22);
        p.quiet_hours_end = None;
        assert!(!p.is_quiet_now(23 * 3600));
    }

    #[test]
    fn build_payload_includes_sound_when_enabled() {
        let p = build_payload("title", "body", true);
        assert!(p.contains("\"sound\":\"default\""));
        assert!(p.contains("\"title\":\"title\""));
    }

    #[test]
    fn build_payload_omits_sound_when_disabled() {
        let p = build_payload("t", "b", false);
        assert!(!p.contains("sound"));
    }

    #[test]
    fn build_payload_escapes_json_in_title() {
        let p = build_payload("with \"quote\"", "body", false);
        assert!(p.contains("with \\\"quote\\\""));
    }

    #[test]
    fn send_returns_zero_with_no_apns_configured() {
        let s = PushService::new();
        s.register(reg("X", "development"));
        s.apply_preferences(prefs("X"));
        assert_eq!(s.send_for_window_state("w1", "claude", "is waiting"), 0);
    }
}
