use regex::Regex;
use std::io::{BufRead, Write};
use std::os::unix::fs::PermissionsExt;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use tracing::{error, info, warn};

pub struct CloudflareTunnel {
    process: Option<Child>,
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
    /// If cloudflared is not installed, downloads it automatically to ~/.local/bin.
    pub async fn start(&mut self, local_port: u16) -> Result<(), String> {
        if self.is_running {
            warn!("Cloudflare tunnel already running");
            return Ok(());
        }

        let binary = match find_cloudflared() {
            Some(b) => b,
            None => {
                info!("cloudflared not found, downloading automatically...");
                download_cloudflared().await?
            }
        };

        info!("Starting cloudflared tunnel via {binary}");

        let mut child = Command::new(&binary)
            .args([
                "tunnel",
                "--url", &format!("http://localhost:{local_port}"),
                "--protocol", "http2",
                "--no-autoupdate",
            ])
            .stderr(Stdio::piped())
            .stdout(Stdio::null())
            .stdin(Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to spawn cloudflared: {e}"))?;

        // Prepare the tunnel log file in a private cache directory
        let log_path = prepare_tunnel_log()
            .map_err(|e| { warn!("Could not prepare tunnel log: {e}"); e })?;

        // Read stderr on a background thread to find the tunnel URL.
        // The thread continues draining stderr after we find the URL so
        // cloudflared doesn't get SIGPIPE. Lines are also written to the log file.
        let stderr = child.stderr.take()
            .ok_or_else(|| "Failed to capture cloudflared stderr".to_string())?;

        let (tx, rx) = mpsc::channel::<String>();
        let url_regex = Regex::new(r"https://[a-zA-Z0-9-]+\.trycloudflare\.com").expect("valid regex");

        std::thread::Builder::new()
            .name("cloudflared-stderr".into())
            .spawn(move || {
                let reader = std::io::BufReader::new(stderr);
                let mut log_file = std::fs::OpenOptions::new()
                    .append(true)
                    .open(&log_path)
                    .ok();
                let mut sent = false;
                for line in reader.lines() {
                    match line {
                        Ok(line) => {
                            // Write to tunnel log file
                            if let Some(ref mut f) = log_file {
                                let _ = writeln!(f, "{line}");
                            }
                            if !sent {
                                if let Some(m) = url_regex.find(&line) {
                                    let _ = tx.send(m.as_str().to_string());
                                    sent = true;
                                    info!("Tunnel URL found, continuing to drain stderr");
                                }
                            }
                        }
                        Err(e) => {
                            warn!("cloudflared stderr read error: {e}");
                            break;
                        }
                    }
                }
                warn!("cloudflared stderr stream ended");
            })
            .map_err(|e| format!("Failed to spawn stderr reader thread: {e}"))?;

        // Wait for the URL with a timeout
        let public_url = tokio::task::spawn_blocking(move || {
            rx.recv_timeout(std::time::Duration::from_secs(30))
        })
        .await
        .map_err(|e| format!("Task failed: {e}"))?
        .map_err(|_| "Timed out or cloudflared exited before producing a URL".to_string())?;

        let ws_url = public_url.replacen("https://", "wss://", 1);
        info!("Cloudflare tunnel established: {public_url}");

        self.process = Some(child);
        self.public_url = public_url;
        self.ws_url = ws_url;
        self.is_running = true;

        Ok(())
    }

    /// Check if the tunnel process is still alive. Returns false if it died.
    pub fn check_health(&mut self) -> bool {
        if let Some(ref mut child) = self.process {
            match child.try_wait() {
                Ok(Some(_status)) => {
                    // Process exited
                    warn!("cloudflared process exited unexpectedly");
                    self.process = None;
                    self.public_url.clear();
                    self.ws_url.clear();
                    self.is_running = false;
                    false
                }
                Ok(None) => true, // still running
                Err(e) => {
                    warn!("Failed to check cloudflared status: {e}");
                    true // assume running
                }
            }
        } else {
            false
        }
    }

    /// Stop the running tunnel.
    pub fn stop(&mut self) {
        if let Some(mut child) = self.process.take() {
            info!("Stopping cloudflare tunnel");
            if let Err(e) = child.kill() {
                error!("Failed to kill cloudflared process: {e}");
            }
            let _ = child.wait();
        }
        self.public_url.clear();
        self.ws_url.clear();
        self.is_running = false;
    }
}

impl Drop for CloudflareTunnel {
    fn drop(&mut self) {
        if let Some(ref mut child) = self.process {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// Return the path for the tunnel log file (~/.cache/quip/tunnel.log or XDG_CACHE_HOME/quip/tunnel.log).
fn tunnel_log_path() -> std::path::PathBuf {
    let cache_dir = std::env::var("XDG_CACHE_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
            std::path::PathBuf::from(home).join(".cache")
        });
    cache_dir.join("quip").join("tunnel.log")
}

/// Ensure the tunnel log directory and file exist with private permissions.
fn prepare_tunnel_log() -> Result<std::path::PathBuf, String> {
    let log_path = tunnel_log_path();
    let log_dir = log_path.parent().unwrap();

    std::fs::create_dir_all(log_dir)
        .map_err(|e| format!("failed to create tunnel log dir: {e}"))?;
    std::fs::set_permissions(log_dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("failed to set log dir permissions: {e}"))?;

    // Create or truncate the log file with 0600 permissions
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&log_path)
        .map_err(|e| format!("failed to create tunnel log file: {e}"))?;
    std::fs::set_permissions(&log_path, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("failed to set log file permissions: {e}"))?;

    Ok(log_path)
}

/// Search common locations for the cloudflared binary.
fn find_cloudflared() -> Option<String> {
    if let Ok(output) = Command::new("which")
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

    let candidates = [
        "/usr/bin/cloudflared",
        "/usr/local/bin/cloudflared",
    ];

    for path in &candidates {
        if std::path::Path::new(path).exists() {
            return Some(path.to_string());
        }
    }

    if let Some(home) = std::env::var_os("HOME") {
        let local_bin = std::path::PathBuf::from(home).join(".local/bin/cloudflared");
        if local_bin.exists() {
            return Some(local_bin.to_string_lossy().to_string());
        }
    }

    None
}

/// Download cloudflared binary to ~/.local/bin and return its path.
async fn download_cloudflared() -> Result<String, String> {
    let arch = std::env::consts::ARCH;
    let cf_arch = match arch {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        "arm" => "arm",
        other => return Err(format!("unsupported architecture for cloudflared: {other}")),
    };

    let url = format!(
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-{cf_arch}"
    );

    let home = std::env::var("HOME").map_err(|_| "HOME not set".to_string())?;
    let bin_dir = std::path::PathBuf::from(&home).join(".local/bin");
    std::fs::create_dir_all(&bin_dir)
        .map_err(|e| format!("failed to create ~/.local/bin: {e}"))?;

    let dest = bin_dir.join("cloudflared");
    info!("Downloading cloudflared from {url}");

    let output = tokio::process::Command::new("curl")
        .args(["-fsSL", "-o", &dest.to_string_lossy(), &url])
        .output()
        .await
        .map_err(|e| format!("failed to run curl: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("failed to download cloudflared: {stderr}"));
    }

    // Verify SHA256 checksum against the published .sha256 file (if available)
    match verify_sha256(&dest, &url).await {
        Ok(()) => {}
        Err(e) if e.contains("404") || e.contains("checksum file") => {
            warn!("SHA256 checksum file not available, skipping verification: {e}");
        }
        Err(e) => {
            let _ = std::fs::remove_file(&dest);
            error!("SHA256 verification failed, deleted unverified binary: {e}");
            return Err(e);
        }
    }

    std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755))
        .map_err(|e| format!("failed to chmod cloudflared: {e}"))?;

    let path = dest.to_string_lossy().to_string();
    info!("cloudflared installed to {path}");
    Ok(path)
}

/// Verify the SHA256 checksum of a downloaded binary against the published .sha256 file.
async fn verify_sha256(binary_path: &std::path::Path, binary_url: &str) -> Result<(), String> {
    let checksum_url = format!("{binary_url}.sha256");
    info!("Downloading SHA256 checksum from {checksum_url}");

    // Download the .sha256 file contents
    let output = tokio::process::Command::new("curl")
        .args(["-fsSL", &checksum_url])
        .output()
        .await
        .map_err(|e| format!("failed to run curl for checksum: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("failed to download checksum file: {stderr}"));
    }

    // Parse expected hash from the .sha256 file (format: "<hash>  <filename>" or just "<hash>")
    let checksum_text = String::from_utf8_lossy(&output.stdout);
    let expected_hash = checksum_text
        .trim()
        .split_whitespace()
        .next()
        .ok_or_else(|| "checksum file is empty".to_string())?
        .to_lowercase();

    // Compute SHA256 of the downloaded binary using sha256sum
    let sha_output = tokio::process::Command::new("sha256sum")
        .arg(binary_path)
        .output()
        .await
        .map_err(|e| format!("failed to run sha256sum: {e}"))?;

    if !sha_output.status.success() {
        let stderr = String::from_utf8_lossy(&sha_output.stderr);
        return Err(format!("sha256sum failed: {stderr}"));
    }

    let sha_text = String::from_utf8_lossy(&sha_output.stdout);
    let computed_hash = sha_text
        .trim()
        .split_whitespace()
        .next()
        .ok_or_else(|| "sha256sum produced no output".to_string())?
        .to_lowercase();

    if computed_hash != expected_hash {
        return Err(format!(
            "SHA256 mismatch: expected {expected_hash}, got {computed_hash}"
        ));
    }

    info!("SHA256 verification passed: {computed_hash}");
    Ok(())
}
