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
///
/// Under XCTest every read, write and delete goes to an in-memory backing and
/// the migration uses a throwaway UserDefaults suite (see "Test backing").
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

    /// The Key ID also rides on the .p8 Keychain item itself (`kSecAttrComment`,
    /// see `APNsKeyStore`), so losing this item (the test suite deleted it
    /// for weeks, 2026-09) no longer loses the kid: the key answers for itself.
    static var keyId: String {
        get {
            performMigrationIfNeeded()
            return resolvedKeyId(stored: read(account: keyIdAccount) ?? "", onKey: APNsKeyStore.keyIdLabel())
        }
        set {
            write(account: keyIdAccount, value: newValue)
            APNsKeyStore.setKeyIdLabel(newValue)
        }
    }

    /// An empty Team ID falls back to the team that signed this app
    /// (`SigningTeam`): the APNs key belongs to the team that ships the iOS
    /// app, which signed this Mac app too. Shown prefilled in Settings.
    static var teamId: String {
        get {
            performMigrationIfNeeded()
            return resolvedTeamId(stored: read(account: teamIdAccount) ?? "",
                                  signingTeam: useTestBacking ? nil : SigningTeam.identifier)
        }
        set { write(account: teamIdAccount, value: newValue) }
    }

    /// Pure: the stored kid wins; an empty one takes the kid the key carries.
    nonisolated static func resolvedKeyId(stored: String, onKey: String?) -> String {
        if !stored.isEmpty { return stored }
        return onKey ?? ""
    }

    /// Pure: the stored team wins; an empty one takes the signing team.
    nonisolated static func resolvedTeamId(stored: String, signingTeam: String?) -> String {
        if !stored.isEmpty { return stored }
        return signingTeam ?? ""
    }

    static var bundleId: String {
        get { performMigrationIfNeeded(); return read(account: bundleIdAccount) ?? defaultBundleId }
        set { write(account: bundleIdAccount, value: newValue) }
    }

    // MARK: - Filename → Key ID

    /// Apple names a downloaded APNs auth key `AuthKey_<KEYID>.p8`, where the
    /// Key ID is exactly 10 uppercase-alphanumeric characters. The Key ID
    /// cannot be derived from the key material itself, so the filename is the
    /// only in-band link between a .p8 and its JWT `kid`. The import flow uses
    /// this to keep the Key ID field in sync with the key actually being
    /// stored — preventing the (key, kid) desync that APNs rejects at send
    /// time with `InvalidProviderToken` (keychain holds key A while the Key ID
    /// field names key B).
    ///
    /// Returns the embedded Key ID, or nil if `filename` doesn't match the
    /// `AuthKey_XXXXXXXXXX(.p8)` shape — callers then leave the field untouched
    /// (e.g. the user renamed the file).
    static func keyId(fromFilename filename: String) -> String? {
        // `.p8`/`.P8` strip only — deliberately NOT deletingPathExtension,
        // which would also accept files with any other trailing extension.
        let stem = filename.lowercased().hasSuffix(".p8") ? String(filename.dropLast(3)) : filename
        guard stem.hasPrefix("AuthKey_") else { return nil }
        let id = String(stem.dropFirst("AuthKey_".count))
        guard id.count == 10,
              id.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else { return nil }
        return id
    }

    // MARK: - Migration

    /// Read once: on the first call, if Keychain is empty AND legacy
    /// UserDefaults keys hold non-empty values, copy them across and
    /// purge the originals. Subsequent calls short-circuit on the
    /// `migrationDoneKey` flag so steady-state reads don't re-probe.
    private static func performMigrationIfNeeded() {
        let d = migrationDefaults
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
            quipPushLog("APNs metadata migrated from UserDefaults to Keychain")
        }

        d.removeObject(forKey: legacyKeyIdDefault)
        d.removeObject(forKey: legacyTeamIdDefault)
        d.removeObject(forKey: legacyBundleIdDefault)
        d.set(true, forKey: migrationDoneKey)
    }

    // MARK: - Test backing

    /// In-memory stand-in for the Keychain under XCTest, as PINStore has.
    ///
    /// The Mac suite is app-hosted and signed, so the test host reaches the
    /// owner's REAL login Keychain. The old tests deleted these three items in
    /// every setUp and tearDown (59 deletes per suite run, so every
    /// tools/check.sh and pre-commit run), which is why push.log said
    /// "APNs not configured" from at least 2026-09-12 on. Only the SecItem
    /// primitives are swapped: the migration logic still runs for real, against
    /// `migrationDefaults`.
    nonisolated(unsafe) private static var testBacking: [String: String] = [:]
    private static var useTestBacking: Bool { SingleInstanceGuard.isRunningTests }

    /// The defaults the legacy migration reads and clears: `.standard` in the
    /// app, a throwaway suite under XCTest, so tests never touch the owner's
    /// com.quip.mac domain. Internal so tests can seed legacy values.
    static var migrationDefaults: UserDefaults { TestSafeDefaults.store("apns-metadata") }

    /// Clean slate for tests: empties the in-memory backing and removes the
    /// legacy keys and the migration flag from the test suite. Does nothing
    /// outside XCTest, so it can never reach the real Keychain or defaults.
    static func wipeForTests() {
        guard useTestBacking else { return }
        testBacking.removeAll()
        let d = migrationDefaults
        for key in [legacyKeyIdDefault, legacyTeamIdDefault, legacyBundleIdDefault, migrationDoneKey] {
            d.removeObject(forKey: key)
        }
    }

    // MARK: - Keychain primitives

    private static func read(account: String) -> String? {
        if useTestBacking { return testBacking[account] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Logged on change only: absent (-25300) means never stored or
        // deleted; anything else is the Keychain refusing the read.
        APNsKeychainLog.noteRead(item: account, status: status)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    @discardableResult
    private static func write(account: String, value: String) -> Bool {
        if useTestBacking { testBacking[account] = value; return true }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
            APNsKeychainLog.noteFailure("SecItemDelete", item: account, status: deleteStatus)
        }

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
            APNsKeychainLog.noteFailure("SecItemAdd", item: account, status: status)
            return false
        }
        return true
    }
}
