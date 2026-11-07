//! Stable per-installation id (`DeviceIdentityMessage.deviceID`, also the
//! mDNS TXT `did`). Generated once and stored in settings (spec 3.1); the
//! phone keys per-backend state (Keychain PIN, paired row) on it, so it must
//! survive restarts, IP and hostname changes.
//!
//! Format: Swift `UUID().uuidString` (upper-case, hyphenated), so it reads like
//! the Mac's own id. Adapted from `QuipLinux/src/services/device_id.rs`, which
//! kept it in its own file; here it lives in `settings.toml`.

use crate::protocol::types::WireUuid;

/// The `--fake-platform` id. Fixed, and different from fake-mac's
/// `FA4E3AC0-0000-4000-8000-000000000001`: the phone merges rows with an equal
/// device id, so no fake may ever share an id with a real host or another fake.
pub const FAKE_DEVICE_ID: &str = "FA4E3AC0-0000-4000-8000-000000000002";

pub fn generate() -> String {
    WireUuid::new_v4().to_swift_string()
}

/// A stored id is kept only if it parses as a Swift UUID.
pub fn is_valid(id: &str) -> bool {
    WireUuid::parse(id).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_ids_are_v4_upper_and_unique() {
        let a = generate();
        let b = generate();
        assert_ne!(a, b);
        assert!(is_valid(&a));
        assert_eq!(a, a.to_uppercase());
        assert_eq!(a.as_bytes()[14], b'4', "version nibble");
    }

    #[test]
    fn fake_id_is_valid_and_not_fake_macs() {
        assert!(is_valid(FAKE_DEVICE_ID));
        assert_ne!(FAKE_DEVICE_ID, "FA4E3AC0-0000-4000-8000-000000000001");
    }

    #[test]
    fn garbage_is_invalid() {
        assert!(!is_valid(""));
        assert!(!is_valid("not-a-uuid"));
    }
}
