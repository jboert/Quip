//! TailscaleService — detects the local Tailscale hostname by shelling out to
//! `tailscale status --json`. Exposes a `ws://HOSTNAME:PORT` URL built from the
//! MagicDNS name (or the 100.x IP as a fallback) and the configured WebSocket port.
//! Supports a manual hostname override that skips the CLI entirely.

use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::state::SharedState;

/// Hardcoded candidate paths for the Tailscale CLI. Checked in order.
const CLI_CANDIDATES: &[&str] = &[
    "/usr/bin/tailscale",
    "/usr/local/bin/tailscale",
    "/opt/tailscale/bin/tailscale",
];

pub struct TailscaleService {
    /// Generation counter — bumped on every refresh so in-flight background
    /// detections can tell they've been superseded before publishing results.
    generation: u64,
}

impl TailscaleService {
    pub fn new() -> Self {
        Self { generation: 0 }
    }

    /// One-shot detection. Spawns a blocking task for the CLI call, then
    /// publishes the result into SharedState. Caller supplies the port so
    /// this file doesn't need to know about AppSettings layout.
    pub async fn refresh(service: Arc<Mutex<Self>>, shared_state: SharedState, port: u16) {
        let my_gen = {
            let mut svc = service.lock().await;
            svc.generation += 1;
            svc.generation
        };

        // Path 1: manual override wins — skip the CLI entirely.
        let override_host = {
            let state = shared_state.read().unwrap();
            state
                .settings
                .general
                .tailscale_hostname_override
                .trim()
                .to_string()
        };
        if !override_host.is_empty() {
            publish(&service, &shared_state, my_gen, Ok(override_host), port).await;
            return;
        }

        // Path 2: auto-detect via CLI on a blocking thread.
        let result = tokio::task::spawn_blocking(detect_via_cli)
            .await
            .unwrap_or_else(|e| Err(format!("Task join error: {e}")));

        publish(&service, &shared_state, my_gen, result, port).await;
    }

    /// Clear all published state. Used when the user switches away from Tailscale mode.
    pub async fn stop(service: Arc<Mutex<Self>>, shared_state: SharedState) {
        {
            let mut svc = service.lock().await;
            svc.generation += 1;
        }
        let mut state = shared_state.write().unwrap();
        state.tailscale_hostname.clear();
        state.tailscale_ws_url.clear();
        state.tailscale_available = false;
        state.tailscale_last_error.clear();
    }
}

async fn publish(
    service: &Arc<Mutex<TailscaleService>>,
    shared_state: &SharedState,
    my_gen: u64,
    result: Result<String, String>,
    port: u16,
) {
    // Bail if a newer refresh() superseded us.
    {
        let svc = service.lock().await;
        if svc.generation != my_gen {
            return;
        }
    }

    let mut state = shared_state.write().unwrap();
    match result {
        Ok(hostname) => {
            state.tailscale_hostname = hostname.clone();
            state.tailscale_ws_url = format!("ws://{hostname}:{port}");
            state.tailscale_available = true;
            state.tailscale_last_error.clear();
            info!("Tailscale hostname detected: {hostname}");
        }
        Err(message) => {
            state.tailscale_hostname.clear();
            state.tailscale_ws_url.clear();
            state.tailscale_available = false;
            state.tailscale_last_error = message.clone();
            warn!("Tailscale detection failed: {message}");
        }
    }
}

/// Runs on a blocking thread. Locates the CLI, shells out to `tailscale status --json`,
/// parses the response, returns either a detected hostname or a human-readable error.
fn detect_via_cli() -> Result<String, String> {
    let cli = locate_cli().ok_or_else(|| {
        "Tailscale not installed — install from tailscale.com".to_string()
    })?;

    let mut child = Command::new(&cli)
        .args(["status", "--json"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to run Tailscale CLI: {e}"))?;

    // Manual 3s timeout — std::process::Child has no built-in.
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => break,
            Ok(None) => {
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err("Tailscale CLI timed out — is the daemon running?".into());
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(format!("Failed to poll Tailscale CLI: {e}")),
        }
    }

    let output = child
        .wait_with_output()
        .map_err(|e| format!("Failed to read Tailscale CLI output: {e}"))?;

    if !output.status.success() {
        return Err("Tailscale not running or not logged in".into());
    }
    if output.stdout.is_empty() {
        return Err("Tailscale CLI returned no output".into());
    }

    let json: Value = serde_json::from_slice(&output.stdout)
        .map_err(|_| "Could not parse Tailscale status JSON".to_string())?;
    let self_node = json
        .get("Self")
        .ok_or_else(|| "No Self node in Tailscale status".to_string())?;

    if let Some(dns) = self_node.get("DNSName").and_then(Value::as_str) {
        if !dns.is_empty() {
            let trimmed = dns.trim_end_matches('.').to_string();
            if !trimmed.is_empty() {
                return Ok(trimmed);
            }
        }
    }

    if let Some(ips) = self_node.get("TailscaleIPs").and_then(Value::as_array) {
        if let Some(first) = ips.first().and_then(Value::as_str) {
            if !first.is_empty() {
                return Ok(first.to_string());
            }
        }
    }

    Err("No Tailscale identity found — try logging in".into())
}

fn locate_cli() -> Option<String> {
    for path in CLI_CANDIDATES {
        if Path::new(path).exists() {
            return Some((*path).to_string());
        }
    }
    // Fall back to PATH lookup.
    if let Ok(output) = Command::new("which").arg("tailscale").output() {
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path.is_empty() {
                return Some(path);
            }
        }
    }
    None
}
