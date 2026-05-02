use std::fs;
use std::io::Write;
use std::path::PathBuf;

use tracing::{info, warn};
use uuid::Uuid;

/// Stable per-installation UUID. Generated on first call and persisted at
/// `~/.config/quip/device_id` (or `$XDG_CONFIG_HOME/quip/device_id`). The
/// phone uses this as the key for per-backend Keychain PINs and paired-
/// backend rows so that state survives URL/hostname changes.
pub fn get_or_create() -> String {
    let path = device_id_path();
    if let Ok(contents) = fs::read_to_string(&path) {
        let trimmed = contents.trim().to_string();
        if Uuid::parse_str(&trimmed).is_ok() {
            return trimmed;
        }
        warn!("Invalid device_id in {}, regenerating", path.display());
    }
    let new_id = Uuid::new_v4().to_string();
    save(&path, &new_id);
    new_id
}

fn save(path: &PathBuf, id: &str) {
    if let Some(parent) = path.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            warn!("Failed to create config dir {}: {e}", parent.display());
            return;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
        }
    }
    match fs::File::create(path) {
        Ok(mut file) => {
            if let Err(e) = file.write_all(id.as_bytes()) {
                warn!("Failed to write device_id to {}: {e}", path.display());
                return;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
            }
            info!("device_id saved to {}", path.display());
        }
        Err(e) => warn!("Failed to create device_id file {}: {e}", path.display()),
    }
}

fn device_id_path() -> PathBuf {
    let config_dir = if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        PathBuf::from(xdg)
    } else if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".config")
    } else {
        PathBuf::from("/tmp")
    };
    config_dir.join("quip").join("device_id")
}
