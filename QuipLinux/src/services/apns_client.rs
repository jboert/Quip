use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};

use super::apns_key_store::ApnsKeyStore;

/// Errors surfaced from `ApnsClient::send`. Mirrors Mac's `APNsError` cases.
/// Distinct cases let the caller respond differently — `Unregistered` →
/// drop device from store, `Throttled` → retry, `BadKey` → surface in UI.
#[derive(Debug, Clone)]
pub enum ApnsError {
    MissingKey,
    InvalidKey(String),
    BadRequest(String),
    Unregistered,
    Throttled,
    ServerError(u16),
    Unknown(u16, String),
}

impl std::fmt::Display for ApnsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingKey => write!(f, "no APNs key configured"),
            Self::InvalidKey(m) => write!(f, "invalid APNs key: {m}"),
            Self::BadRequest(m) => write!(f, "APNs bad request: {m}"),
            Self::Unregistered => write!(f, "APNs reports device unregistered"),
            Self::Throttled => write!(f, "APNs throttled"),
            Self::ServerError(s) => write!(f, "APNs server error {s}"),
            Self::Unknown(s, r) => write!(f, "APNs {s}: {r}"),
        }
    }
}

impl std::error::Error for ApnsError {}

/// Cached JWT — APNs rejects tokens older than 60 minutes, so we rotate at
/// 50 min to leave headroom (matching Mac's `CachedJWT.isExpired`).
struct CachedJwt {
    token: String,
    issued_at: Instant,
}

impl CachedJwt {
    fn is_expired(&self) -> bool {
        self.issued_at.elapsed() > Duration::from_secs(50 * 60)
    }
}

#[derive(Debug, Clone, Serialize)]
struct JwtClaims {
    iss: String,
    iat: i64,
}

/// Per-device record. Mirrors Mac's `RegisteredPushDevice`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RegisteredPushDevice {
    pub token: String,
    pub environment: String, // "development" | "production"
    pub registered_at: u64,  // unix seconds
}

/// Signs ES256 JWTs with the .p8 key and POSTs them + an alert payload to
/// Apple's HTTP/2 APNs endpoint via reqwest's HTTP/2 client. Mirrors
/// `QuipMac/Services/APNsClient.swift`.
pub struct ApnsClient {
    pub key_id: String,
    pub team_id: String,
    pub bundle_id: String,
    encoding_key: EncodingKey,
    cached_jwt: Mutex<Option<CachedJwt>>,
    http: reqwest::blocking::Client,
}

impl ApnsClient {
    pub fn new(key_id: String, team_id: String, bundle_id: String) -> Result<Arc<Self>, ApnsError> {
        let pem = ApnsKeyStore::get().ok_or(ApnsError::MissingKey)?;
        Self::new_from_pem(&pem, key_id, team_id, bundle_id)
    }

    /// Construct from an explicit PEM byte slice instead of the configured
    /// keystore. Lets tests use a throwaway key without touching the user's
    /// config dir.
    pub fn new_from_pem(
        pem: &[u8],
        key_id: String,
        team_id: String,
        bundle_id: String,
    ) -> Result<Arc<Self>, ApnsError> {
        let encoding_key = EncodingKey::from_ec_pem(pem)
            .map_err(|e| ApnsError::InvalidKey(format!("PEM parse failed: {e}")))?;

        // HTTP/2 is required by Apple's APNs gateway. reqwest supports it
        // when `http2` is in the feature list (which we set in Cargo.toml).
        let http = reqwest::blocking::Client::builder()
            .http2_prior_knowledge()
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| ApnsError::Unknown(0, format!("HTTP client init failed: {e}")))?;

        Ok(Arc::new(Self {
            key_id,
            team_id,
            bundle_id,
            encoding_key,
            cached_jwt: Mutex::new(None),
            http,
        }))
    }

    /// Build a fresh JWT. Public so tests can inspect the structure.
    pub fn make_jwt(&self) -> Result<String, ApnsError> {
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());
        let claims = JwtClaims {
            iss: self.team_id.clone(),
            iat: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0),
        };
        encode(&header, &claims, &self.encoding_key)
            .map_err(|e| ApnsError::InvalidKey(format!("JWT sign failed: {e}")))
    }

    fn current_jwt(&self) -> Result<String, ApnsError> {
        let mut guard = self.cached_jwt.lock().expect("apns jwt poisoned");
        if let Some(c) = guard.as_ref() {
            if !c.is_expired() {
                return Ok(c.token.clone());
            }
        }
        let fresh = self.make_jwt()?;
        *guard = Some(CachedJwt {
            token: fresh.clone(),
            issued_at: Instant::now(),
        });
        Ok(fresh)
    }

    /// POST a pre-encoded JSON alert payload to a single device.
    /// `payload_json` should already be the JSON object body; we don't
    /// touch it. `collapse_id` truncated to 64 bytes per APNs spec.
    /// On 410/Unregistered/BadDeviceToken the caller should drop the
    /// device from its registry — `Err(Unregistered)` signals that.
    /// 429/503 retries once with a 2s sleep, then surfaces `Throttled`.
    pub fn send(
        &self,
        payload_json: &str,
        device: &RegisteredPushDevice,
        collapse_id: Option<&str>,
    ) -> Result<(), ApnsError> {
        match self.do_send(payload_json, device, collapse_id) {
            Err(ApnsError::Throttled) => {
                std::thread::sleep(Duration::from_secs(2));
                self.do_send(payload_json, device, collapse_id)
            }
            other => other,
        }
    }

    fn do_send(
        &self,
        payload_json: &str,
        device: &RegisteredPushDevice,
        collapse_id: Option<&str>,
    ) -> Result<(), ApnsError> {
        let host = if device.environment == "production" {
            "api.push.apple.com"
        } else {
            "api.sandbox.push.apple.com"
        };
        let url = format!("https://{host}/3/device/{}", device.token);

        let mut req = self
            .http
            .post(&url)
            .header("apns-push-type", "alert")
            .header("apns-topic", &self.bundle_id)
            .header("apns-priority", "10")
            .header("authorization", format!("bearer {}", self.current_jwt()?))
            .header("content-type", "application/json")
            .body(payload_json.to_string());

        if let Some(c) = collapse_id.filter(|s| !s.is_empty()) {
            // 64-byte cap per APNs spec.
            let truncated = if c.len() > 64 { &c[..64] } else { c };
            req = req.header("apns-collapse-id", truncated);
        }

        let resp = req.send().map_err(|e| {
            // Network-level failure (TLS, DNS, etc.). Caller may want to
            // retry or surface to the user; treat as Unknown for parity
            // with Mac's NSURLErrorDomain catch-all.
            ApnsError::Unknown(0, format!("send failed: {e}"))
        })?;

        let status = resp.status().as_u16();
        let body = resp.text().unwrap_or_default();
        let reason = extract_reason(&body);

        match status {
            200 => Ok(()),
            400 => {
                if reason == "BadDeviceToken"
                    || reason == "DeviceTokenNotForTopic"
                    || reason == "Unregistered"
                {
                    Err(ApnsError::Unregistered)
                } else {
                    Err(ApnsError::BadRequest(reason))
                }
            }
            403 => Err(ApnsError::InvalidKey(reason)),
            410 => Err(ApnsError::Unregistered),
            429 | 503 => Err(ApnsError::Throttled),
            500..=599 => Err(ApnsError::ServerError(status)),
            other => Err(ApnsError::Unknown(other, reason)),
        }
    }
}

fn extract_reason(body: &str) -> String {
    #[derive(Deserialize)]
    struct Body {
        reason: Option<String>,
    }
    serde_json::from_str::<Body>(body)
        .ok()
        .and_then(|b| b.reason)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// JWT signing requires a real EC P-256 key, which we'd have to embed
    /// or generate; either way the unit test would just be exercising the
    /// `jsonwebtoken` crate. The error paths below cover the failure
    /// shapes a wrong .p8 file produces.

    #[test]
    fn extract_reason_parses_apns_error_body() {
        assert_eq!(extract_reason(r#"{"reason":"BadDeviceToken"}"#), "BadDeviceToken");
        assert_eq!(extract_reason("not json"), "");
        assert_eq!(extract_reason(""), "");
    }

    #[test]
    fn invalid_pem_surfaces_clear_error() {
        let r = ApnsClient::new_from_pem(b"not a real PEM", "k".into(), "t".into(), "b".into());
        assert!(matches!(r, Err(ApnsError::InvalidKey(_))));
    }
}
