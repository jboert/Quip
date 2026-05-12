import Foundation
import Security

/// Wraps Keychain reads/writes for the APNs metadata triple
/// (keyId / teamId / bundleId). These aren't password-equivalent the way
/// the .p8 itself is — keyId is a 10-char public-ish identifier, teamId
/// is the developer-team ID printed on every signed binary, bundleId is
/// just an app identifier. But they're useful enough to an attacker
/// (combined with the .p8 from a separate compromise they form the
/// complete APNs send credential), so we keep them in the same trust
/// envelope as the .p8 instead of UserDefaults. (GH #22.)
///
/// Migration: first call to `keyId` / `teamId` / `bundleId` reads
/// Keychain. If empty AND the legacy `apnsKeyId` / `apnsTeamId` /
/// `apnsBundleId` UserDefaults keys hold values, those values get
/// migrated to Keychain in one shot, the UserDefaults entries are
/// removed, and a one-line log marks the migration. Idempotent — second
/// run finds the Keychain populated and skips.
///
/// Service key: `com.quip.mac.apns-metadata`
/// Account keys: `keyId`, `teamId`, `bundleId`
enum APNsMetadataStore {
    private static let service = "com.quip.mac.apns-metadata"

    private static let keyIdAccount = "keyId"
    private static let teamIdAccount = "teamId"
    private static let bundleIdAccount = "bundleId"

    private static let legacyKeyIdDefault = "apnsKeyId"
    private static let legacyTeamIdDefault = "apnsTeamId"
    private static let legacyBundleIdDefault = "apnsBundleId"

    private static let defaultBundleId = "com.quip.QuipiOS"

    /// Has the one-time migration from UserDefaults to Keychain run?
    /// Tracked in UserDefaults itself so a fresh install with a blank
    /// Keychain doesn't keep retrying the migration on every read.
    private static let migrationDoneKey = "apnsMetadataMigrationV1Done"

    static var keyId: String {
        get { performMigrationIfNeeded(); return read(account: keyIdAccount) ?? "" }
        set { write(account: keyIdAccount, value: newValue) }
    }

    static var teamId: String {
        get { performMigrationIfNeeded(); return read(account: teamIdAccount) ?? "" }
        set { write(account: teamIdAccount, value: newValue) }
    }

    static var bundleId: String {
        get { performMigrationIfNeeded(); return read(account: bundleIdAccount) ?? defaultBundleId }
        set { write(account: bundleIdAccount, value: newValue) }
    }

    // MARK: - Migration

    /// Read once: on the first call, if Keychain is empty AND legacy
    /// UserDefaults keys hold non-empty values, copy them across and
    /// purge the originals. Subsequent calls short-circuit on the
    /// `migrationDoneKey` flag so steady-state reads don't re-probe.
    private static func performMigrationIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: migrationDoneKey) else { return }

        let legacyKeyId = d.string(forKey: legacyKeyIdDefault) ?? ""
        let legacyTeamId = d.string(forKey: legacyTeamIdDefault) ?? ""
        let legacyBundleId = d.string(forKey: legacyBundleIdDefault) ?? ""

        let kcKeyId = read(account: keyIdAccount)
        let kcTeamId = read(account: teamIdAccount)
        let kcBundleId = read(account: bundleIdAccount)

        // Only migrate the fields that are NOT already in Keychain — gives
        // a partial-migration retry path if the previous run only managed
        // some of the writes before being killed.
        if kcKeyId == nil, !legacyKeyId.isEmpty { write(account: keyIdAccount, value: legacyKeyId) }
        if kcTeamId == nil, !legacyTeamId.isEmpty { write(account: teamIdAccount, value: legacyTeamId) }
        if kcBundleId == nil, !legacyBundleId.isEmpty { write(account: bundleIdAccount, value: legacyBundleId) }

        let migratedAny = (kcKeyId == nil && !legacyKeyId.isEmpty)
            || (kcTeamId == nil && !legacyTeamId.isEmpty)
            || (kcBundleId == nil && !legacyBundleId.isEmpty)
        if migratedAny {
            print("[APNsMetadataStore] migrated APNs metadata to Keychain")
        }

        d.removeObject(forKey: legacyKeyIdDefault)
        d.removeObject(forKey: legacyTeamIdDefault)
        d.removeObject(forKey: legacyBundleIdDefault)
        d.set(true, forKey: migrationDoneKey)
    }

    // MARK: - Keychain primitives

    private static func read(account: String) -> String? {
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
            print("[APNsMetadataStore] SecItemCopyMatching(\(account)) failed: \(status)")
        }
        return nil
    }

    @discardableResult
    private static func write(account: String, value: String) -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Empty string is a valid clear-out — store it so the field round-trips
        // (UI bind to AppStorage-equivalent should still see "" not nil).
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
            print("[APNsMetadataStore] SecItemAdd(\(account)) failed: \(status)")
            return false
        }
        return true
    }
}
