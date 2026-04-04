use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use tracing::{info, warn};

/// Manages a 6-digit PIN for WebSocket client authentication.
/// PIN is stored in ~/.config/quip/pin (or XDG_CONFIG_HOME/quip/pin).
pub struct PINManager {
    pin: Arc<RwLock<String>>,
}

impl PINManager {
    /// Load existing PIN or generate a new one on first launch.
    pub fn new() -> Self {
        let path = Self::pin_path();
        let pin = match fs::read_to_string(&path) {
            Ok(contents) => {
                let trimmed = contents.trim().to_string();
                if trimmed.len() >= 6 && trimmed.chars().all(|c| c.is_ascii_digit()) {
                    info!("Loaded PIN from {}", path.display());
                    trimmed
                } else {
                    warn!("Invalid PIN in {}, regenerating", path.display());
                    let new_pin = Self::generate_pin();
                    Self::save_pin_to_disk(&path, &new_pin);
                    new_pin
                }
            }
            Err(_) => {
                info!("No PIN file found, generating new PIN");
                let new_pin = Self::generate_pin();
                Self::save_pin_to_disk(&path, &new_pin);
                new_pin
            }
        };

        Self {
            pin: Arc::new(RwLock::new(pin)),
        }
    }

    /// Get the current PIN.
    pub fn pin(&self) -> String {
        self.pin.read().unwrap().clone()
    }

    /// Generate a new PIN and save it to disk.
    pub fn regenerate(&self) {
        let new_pin = Self::generate_pin();
        Self::save_pin_to_disk(&Self::pin_path(), &new_pin);
        *self.pin.write().unwrap() = new_pin;
        info!("PIN regenerated");
    }

    /// Set a custom PIN and save it to disk.
    pub fn set_pin(&self, new_pin: &str) {
        Self::save_pin_to_disk(&Self::pin_path(), new_pin);
        *self.pin.write().unwrap() = new_pin.to_string();
        info!("PIN updated");
    }

    /// Check if a given PIN matches the stored PIN.
    pub fn verify(&self, candidate: &str) -> bool {
        *self.pin.read().unwrap() == candidate
    }

    fn generate_pin() -> String {
        let n: u32 = rand::random_range(0..1_000_000);
        format!("{:06}", n)
    }

    fn pin_path() -> PathBuf {
        let config_dir = dirs_config_dir().join("quip");
        config_dir.join("pin")
    }

    fn save_pin_to_disk(path: &PathBuf, pin: &str) {
        if let Some(parent) = path.parent() {
            if let Err(e) = fs::create_dir_all(parent) {
                warn!("Failed to create config dir {}: {e}", parent.display());
                return;
            }
            // Set directory permissions to 0700
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
            }
        }

        match fs::File::create(path) {
            Ok(mut file) => {
                if let Err(e) = file.write_all(pin.as_bytes()) {
                    warn!("Failed to write PIN to {}: {e}", path.display());
                    return;
                }
                // Set file permissions to 0600
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
                }
                info!("PIN saved to {}", path.display());
            }
            Err(e) => warn!("Failed to create PIN file {}: {e}", path.display()),
        }
    }
}

impl Clone for PINManager {
    fn clone(&self) -> Self {
        Self {
            pin: Arc::clone(&self.pin),
        }
    }
}

/// Get XDG_CONFIG_HOME or default to ~/.config
fn dirs_config_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        PathBuf::from(xdg)
    } else if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".config")
    } else {
        PathBuf::from("/tmp")
    }
}
