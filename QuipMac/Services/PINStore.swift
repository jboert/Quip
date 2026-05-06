import Foundation
import Security

/// Wraps Keychain reads/writes for the Mac auth PIN. The PIN is the
/// shared secret between the Mac server and any paired iOS device on
/// the LAN (or via the cloudflared tunnel). UserDefaults stored it as
/// plaintext at-rest; Keychain ties it to the user's login keychain
/// (locked when the screen is locked) and keeps it out of any plist
/// surface that Time Machine / Migration Assistant / casual `defaults
/// read` would expose. (GH #14.)
///
/// Migration: first call to `pin` reads Keychain. If empty AND the
/// legacy `QuipAuthPIN` UserDefaults key holds a non-empty value, the
/// value is migrated to Keychain in one shot, the UserDefaults entry
/// is removed, and a one-line log marks the migration. Idempotent —
/// second run finds the Keychain populated and skips.
///
/// Service key: `com.quip.mac.pin`
/// Account key: `auth`
enum PINStore {
    private static let service = "com.quip.mac.pin"
    private static let account = "auth"

    private static let legacyDefaultKey = "QuipAuthPIN"

    /// Has the one-time migration from UserDefaults to Keychain run?
    /// Tracked in UserDefaults itself so a fresh install with a blank
    /// Keychain doesn't keep retrying the migration on every read.
    private static let migrationDoneKey = "pinMigrationV1Done"

    /// Read the stored PIN, performing migration if needed.
    /// Returns nil if no PIN has ever been stored (fresh install).
    static var pin: String? {
        get {
            performMigrationIfNeeded()
            return read()
        }
        set {
            if let value = newValue, !value.isEmpty {
                write(value: value)
            } else {
                delete()
            }
        }
    }

    // MARK: - Migration

    /// Read once: on the first call, if Keychain is empty AND the
    /// legacy `QuipAuthPIN` UserDefaults key holds a non-empty value,
    /// copy it across and purge the original. Subsequent calls
    /// short-circuit on the `migrationDoneKey` flag so steady-state
    /// reads don't re-probe.
    static func performMigrationIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: migrationDoneKey) else { return }

        let legacy = d.string(forKey: legacyDefaultKey) ?? ""
        let kc = read()

        if kc == nil, !legacy.isEmpty {
            write(value: legacy)
            print("[PINStore] migrated PIN to Keychain")
        }

        d.removeObject(forKey: legacyDefaultKey)
        d.set(true, forKey: migrationDoneKey)
    }

    // MARK: - Test hooks

    /// Reset the migration flag — for tests only. Production code never
    /// re-runs migration in the same process lifetime.
    static func resetMigrationFlagForTests() {
        UserDefaults.standard.removeObject(forKey: migrationDoneKey)
    }

    /// Wipe both the Keychain entry and the legacy UserDefaults key —
    /// for tests that need a clean slate.
    static func wipeForTests() {
        delete()
        UserDefaults.standard.removeObject(forKey: legacyDefaultKey)
        UserDefaults.standard.removeObject(forKey: migrationDoneKey)
    }

    // MARK: - Keychain primitives

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        if status != errSecItemNotFound {
            print("[PINStore] SecItemCopyMatching failed: \(status)")
        }
        return nil
    }

    @discardableResult
    private static func write(value: String) -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let data = value.data(using: .utf8) else { return false }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[PINStore] SecItemAdd failed: \(status)")
            return false
        }
        return true
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
