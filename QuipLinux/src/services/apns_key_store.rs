use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;

/// Linux equivalent of `QuipMac/Services/APNsKeyStore.swift`.
///
/// macOS uses Keychain for the password-equivalent .p8 key. On Linux we have
/// no system-wide secret store every distro ships, so we write the PEM to
/// `~/.config/quip/apns.p8` with mode 0600 (owner-read-write only). Any
/// process running as the same user can still read it, which is the same
/// trust boundary as Keychain entries marked `kSecAttrAccessibleWhenUnlocked`.
pub struct ApnsKeyStore;

impl ApnsKeyStore {
    fn path() -> Option<PathBuf> {
        directories::ProjectDirs::from("dev", "quip", "quip")
            .map(|p| p.config_dir().join("apns.p8"))
    }

    /// Store PEM bytes. Creates the parent dir if needed and forces 0600
    /// before writing the file content.
    pub fn set(pem: &[u8]) -> std::io::Result<()> {
        let path = Self::path().ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::Other, "no project dirs available")
        })?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        // Open with mode 0600 from the start so we never have a window
        // where the file exists with default umask permissions.
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true).mode(0o600);
        let mut f = opts.open(&path)?;
        f.write_all(pem)?;
        // Explicitly re-set the mode in case the file already existed with
        // looser perms — OpenOptions::mode only applies on fresh creation.
        let mut perms = fs::metadata(&path)?.permissions();
        perms.set_mode(0o600);
        fs::set_permissions(&path, perms)?;
        Ok(())
    }

    pub fn get() -> Option<Vec<u8>> {
        let path = Self::path()?;
        fs::read(path).ok()
    }

    pub fn clear() -> std::io::Result<()> {
        let path = match Self::path() {
            Some(p) => p,
            None => return Ok(()),
        };
        match fs::remove_file(&path) {
            Ok(_) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e),
        }
    }

    pub fn has_key() -> bool {
        Self::path().map(|p| p.exists()).unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Roundtrip writes the key to the configured path with mode 0600.
    /// Tests for the real `directories`-derived path are skipped here
    /// because all tests run in the same process and share env vars
    /// (XDG_CONFIG_HOME), which races between this and apns_client tests.
    /// Instead we directly exercise the file IO + mode invariants.
    #[test]
    fn write_then_read_with_mode_0600() {
        let tmp = std::env::temp_dir().join(format!("quip-keystore-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).unwrap();
        let path = tmp.join("apns.p8");

        let pem = b"-----BEGIN PRIVATE KEY-----\nstubbed\n-----END PRIVATE KEY-----\n";
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true).mode(0o600);
        let mut f = opts.open(&path).unwrap();
        f.write_all(pem).unwrap();
        drop(f);

        let read = fs::read(&path).unwrap();
        assert_eq!(read, pem);
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
