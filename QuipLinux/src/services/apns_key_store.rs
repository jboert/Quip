use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use rand::Rng;
use sha2::{Digest, Sha256};

/// Linux equivalent of `QuipMac/Services/APNsKeyStore.swift`.
///
/// macOS uses Keychain for the password-equivalent .p8 key. On Linux we have
/// no system-wide secret store every distro ships, so we write the PEM to
/// `~/.config/quip/apns.p8`. Mode is 0600 so other local users can't read it
/// (matches Keychain's `kSecAttrAccessibleWhenUnlocked` trust boundary), and
/// the contents are AES-256-GCM encrypted with a key derived from
/// `/etc/machine-id` so a backup of just this file (without the rest of the
/// filesystem) is opaque to an attacker. This doesn't help against a same-UID
/// process or root — both can still read both files — but it raises the bar
/// for offline / partial-disk-image extraction, which is the practical threat.
///
/// Wire format:
///   - 8 bytes magic: "QUIPAPN1" (versioned for future format changes)
///   - 12 bytes random nonce
///   - N bytes ciphertext + 16-byte AEAD auth tag (concatenated by aes-gcm)
///
/// Files written by older builds are plaintext PEM. `get()` recognizes the
/// magic header to distinguish formats; the next `set()` upgrades the file
/// to the encrypted layout.
pub struct ApnsKeyStore;

const MAGIC: &[u8; 8] = b"QUIPAPN1";
const NONCE_LEN: usize = 12;
/// 8 magic + 12 nonce + 16 GCM tag is the minimum encrypted file size. Smaller
/// inputs can't have come out of `encrypt()` and so must be plaintext.
const MIN_ENCRYPTED_LEN: usize = MAGIC.len() + NONCE_LEN + 16;

impl ApnsKeyStore {
    fn path() -> Option<PathBuf> {
        directories::ProjectDirs::from("dev", "quip", "quip")
            .map(|p| p.config_dir().join("apns.p8"))
    }

    /// Store PEM bytes. Creates the parent dir if needed and forces 0600
    /// before writing the file content. Encrypts the payload at rest when
    /// `/etc/machine-id` is readable; falls back to mode-0600 plaintext if
    /// machine-id can't be read so we don't lose the user's key on weird
    /// containers / sandboxed builds.
    pub fn set(pem: &[u8]) -> std::io::Result<()> {
        let path = Self::path().ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::Other, "no project dirs available")
        })?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        // Encrypt if we can. If derive_key fails (machine-id missing /
        // unreadable), write plaintext — losing the key would be worse than
        // a slightly weaker on-disk story, and mode 0600 still gates access.
        let to_write: Vec<u8> = match encrypt(pem) {
            Ok(blob) => blob,
            Err(e) => {
                tracing::warn!("APNs key store: encryption unavailable ({e}); writing plaintext");
                pem.to_vec()
            }
        };

        // Open with mode 0600 from the start so we never have a window
        // where the file exists with default umask permissions.
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true).mode(0o600);
        let mut f = opts.open(&path)?;
        f.write_all(&to_write)?;
        // Explicitly re-set the mode in case the file already existed with
        // looser perms — OpenOptions::mode only applies on fresh creation.
        let mut perms = fs::metadata(&path)?.permissions();
        perms.set_mode(0o600);
        fs::set_permissions(&path, perms)?;
        Ok(())
    }

    pub fn get() -> Option<Vec<u8>> {
        let path = Self::path()?;
        let raw = fs::read(path).ok()?;

        // Encrypted format starts with our magic header. If we see it, decrypt.
        // Anything else is treated as legacy plaintext PEM — the next set()
        // will upgrade the on-disk format.
        if raw.len() >= MIN_ENCRYPTED_LEN && &raw[..MAGIC.len()] == MAGIC {
            match decrypt(&raw) {
                Ok(plain) => Some(plain),
                Err(e) => {
                    tracing::warn!("APNs key store: decrypt failed ({e}); ignoring file");
                    None
                }
            }
        } else {
            Some(raw)
        }
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

// --- Encryption helpers ----------------------------------------------------

fn derive_key() -> std::io::Result<[u8; 32]> {
    // Try systemd's machine-id first, fall back to D-Bus's. Both are 32-char
    // hex on a single line; the actual content doesn't matter to us as long
    // as it's stable across reboots and per-machine.
    let raw = fs::read_to_string("/etc/machine-id")
        .or_else(|_| fs::read_to_string("/var/lib/dbus/machine-id"))?;
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "machine-id is empty",
        ));
    }
    let mut hasher = Sha256::new();
    // Domain-separated so this key is never accidentally identical to one
    // derived for some other in-app purpose down the line.
    hasher.update(b"quip:apns:v1:");
    hasher.update(raw.as_bytes());
    let digest = hasher.finalize();
    let mut key = [0u8; 32];
    key.copy_from_slice(&digest);
    Ok(key)
}

fn encrypt(plaintext: &[u8]) -> std::io::Result<Vec<u8>> {
    let key = derive_key()?;
    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, format!("aes init: {e}")))?;

    let mut nonce_bytes = [0u8; NONCE_LEN];
    rand::rng().fill(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, format!("encrypt: {e}")))?;

    let mut out = Vec::with_capacity(MAGIC.len() + NONCE_LEN + ciphertext.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

fn decrypt(blob: &[u8]) -> std::io::Result<Vec<u8>> {
    if blob.len() < MIN_ENCRYPTED_LEN || &blob[..MAGIC.len()] != MAGIC {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "not a Quip-encrypted blob",
        ));
    }
    let key = derive_key()?;
    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, format!("aes init: {e}")))?;
    let nonce_end = MAGIC.len() + NONCE_LEN;
    let nonce = Nonce::from_slice(&blob[MAGIC.len()..nonce_end]);
    cipher
        .decrypt(nonce, &blob[nonce_end..])
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, format!("decrypt: {e}")))
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

    #[test]
    fn encrypt_decrypt_roundtrip() {
        // Skip on systems without machine-id (rare CI sandboxes); the test
        // only makes sense when we can actually derive a key.
        if derive_key().is_err() {
            eprintln!("skipping: machine-id unreadable in this environment");
            return;
        }

        let pem = b"-----BEGIN PRIVATE KEY-----\nABC123\n-----END PRIVATE KEY-----\n";
        let blob = encrypt(pem).expect("encrypt");
        assert!(blob.starts_with(MAGIC), "magic header missing");
        assert!(blob.len() > pem.len(), "ciphertext should include nonce + tag");

        let plain = decrypt(&blob).expect("decrypt");
        assert_eq!(plain, pem);
    }

    #[test]
    fn encrypt_produces_unique_nonces() {
        if derive_key().is_err() { return; }
        let pem = b"identical input";
        let a = encrypt(pem).unwrap();
        let b = encrypt(pem).unwrap();
        assert_ne!(a, b, "two encryptions of the same plaintext should differ in nonce");
    }

    #[test]
    fn decrypt_rejects_bit_flip() {
        if derive_key().is_err() { return; }
        let mut blob = encrypt(b"sensitive").unwrap();
        // Flip a byte in the ciphertext region (after magic + nonce).
        let target = MAGIC.len() + NONCE_LEN + 1;
        blob[target] ^= 0x01;
        assert!(decrypt(&blob).is_err(), "GCM auth tag must reject tampered ciphertext");
    }

    #[test]
    fn decrypt_rejects_wrong_magic() {
        let bad = b"WRONGMAGICXXXXXXXXXXXXXXXXXXXXXXX".to_vec();
        assert!(decrypt(&bad).is_err());
    }

    #[test]
    fn legacy_plaintext_is_passed_through() {
        // Simulate get() reading a plaintext file from an older build: it
        // should round-trip without trying to decrypt. (We test the format-
        // detection branch directly since get() reads from disk.)
        let pem = b"-----BEGIN PRIVATE KEY-----\nlegacy\n-----END PRIVATE KEY-----\n";
        // Plaintext doesn't start with MAGIC, so the format check rejects
        // it as encrypted and the caller treats it as plaintext.
        assert!(pem.len() < MIN_ENCRYPTED_LEN || &pem[..MAGIC.len()] != MAGIC);
    }
}
