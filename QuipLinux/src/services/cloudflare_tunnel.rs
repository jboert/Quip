use regex::Regex;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tracing::{error, info, warn};

pub struct CloudflareTunnel {
    process: Option<tokio::process::Child>,
    public_url: String,
    ws_url: String,
    is_running: bool,
}

impl CloudflareTunnel {
    pub fn new() -> Self {
        Self {
            process: None,
            public_url: String::new(),
            ws_url: String::new(),
            is_running: false,
        }
    }

    pub fn public_url(&self) -> &str {
        &self.public_url
    }

    pub fn ws_url(&self) -> &str {
        &self.ws_url
    }

    pub fn is_running(&self) -> bool {
        self.is_running
    }

    /// Start a Cloudflare quick tunnel pointing at the given local port.
    pub async fn start(&mut self, local_port: u16) -> Result<(), String> {
        if self.is_running {
            warn!("Cloudflare tunnel already running");
            return Ok(());
        }

        let binary = find_cloudflared().ok_or_else(|| {
            "cloudflared binary not found in PATH, /usr/bin, or ~/.local/bin".to_string()
        })?;

        info!("Starting cloudflared tunnel via {binary}");

        let mut child = Command::new(&binary)
            .args(["tunnel", "--url", &format!("http://localhost:{local_port}")])
            .stderr(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("Failed to spawn cloudflared: {e}"))?;

        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "Failed to capture cloudflared stderr".to_string())?;

        let url_regex =
            Regex::new(r"https://[a-zA-Z0-9-]+\.trycloudflare\.com").expect("valid regex");

        let mut reader = BufReader::new(stderr).lines();

        // Read stderr lines until we find the public URL or the process exits.
        let mut found_url = None;
        let timeout = tokio::time::sleep(std::time::Duration::from_secs(30));
        tokio::pin!(timeout);

        loop {
            tokio::select! {
                line_result = reader.next_line() => {
                    match line_result {
                        Ok(Some(line)) => {
                            if let Some(m) = url_regex.find(&line) {
                                found_url = Some(m.as_str().to_string());
                                break;
                            }
                        }
                        Ok(None) => {
                            return Err("cloudflared exited before producing a URL".into());
                        }
                        Err(e) => {
                            return Err(format!("Error reading cloudflared stderr: {e}"));
                        }
                    }
                }
                _ = &mut timeout => {
                    // Kill the child since we timed out.
                    let _ = child.kill().await;
                    return Err("Timed out waiting for cloudflared URL".into());
                }
            }
        }

        let public_url = found_url.ok_or("No URL captured from cloudflared")?;
        let ws_url = public_url.replacen("https://", "wss://", 1);

        info!("Cloudflare tunnel established: {public_url}");

        self.process = Some(child);
        self.public_url = public_url;
        self.ws_url = ws_url;
        self.is_running = true;

        Ok(())
    }

    /// Stop the running tunnel.
    pub async fn stop(&mut self) {
        if let Some(mut child) = self.process.take() {
            info!("Stopping cloudflare tunnel");
            if let Err(e) = child.kill().await {
                error!("Failed to kill cloudflared process: {e}");
            }
        }
        self.public_url.clear();
        self.ws_url.clear();
        self.is_running = false;
    }
}

impl Drop for CloudflareTunnel {
    fn drop(&mut self) {
        // Best-effort synchronous cleanup; kill_on_drop handles the rest.
        if let Some(ref mut child) = self.process {
            let _ = child.start_kill();
        }
    }
}

/// Search common locations for the cloudflared binary.
fn find_cloudflared() -> Option<String> {
    // Check PATH first via `which`.
    if let Ok(output) = std::process::Command::new("which")
        .arg("cloudflared")
        .output()
    {
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path.is_empty() {
                return Some(path);
            }
        }
    }

    // Fallback locations.
    let candidates = [
        "/usr/bin/cloudflared",
        "/usr/local/bin/cloudflared",
    ];

    for path in &candidates {
        if std::path::Path::new(path).exists() {
            return Some(path.to_string());
        }
    }

    // ~/.local/bin/cloudflared
    if let Some(home) = std::env::var_os("HOME") {
        let local_bin = std::path::PathBuf::from(home).join(".local/bin/cloudflared");
        if local_bin.exists() {
            return Some(local_bin.to_string_lossy().to_string());
        }
    }

    None
}
