import Foundation
import Security

/// Wraps Keychain reads/writes for the APNs .p8 auth key. The key is a
/// password-equivalent secret (anyone holding it can send pushes to every
/// device registered to the developer account's bundle ID), so it MUST
/// NOT land in UserDefaults, Info.plist, or any other unencrypted store.
///
/// Service key: `com.quip.mac.apns`
/// Account key: `p8key`
///
/// The stored value is the raw .p8 file contents (PEM-encoded PKCS#8
/// private key with `-----BEGIN PRIVATE KEY-----` headers). Call
/// `APNsClient` layer does the parse via CryptoKit; this layer is
/// storage-only and type-ignorant.
///
/// Under XCTest set/get/clear go to an in-memory backing instead (see
/// "Test backing"), so no test can read, replace or delete the real key.
enum APNsKeyStore {
    private static let service = "com.quip.mac.apns"
    private static let account = "p8key"

    /// Store the PEM contents. Overwrites any existing value.
    /// Returns true on success. Logs + returns false on Keychain errors;
    /// Settings UI shows the error via a status label.
    @discardableResult
    static func set(_ pemData: Data) -> Bool {
        if useTestBacking { testBacking = pemData; return true }
        // Delete any existing item first — otherwise SecItemAdd returns
        // errSecDuplicateItem. Using SecItemUpdate would also work, but
        // delete-then-add handles the "first write" case without branching.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
            APNsKeychainLog.noteFailure("SecItemDelete", item: account, status: deleteStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: pemData,
            // Accessible when the Mac is unlocked — APNs sends only fire
            // while the user's session is active anyway.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            APNsKeychainLog.noteFailure("SecItemAdd", item: account, status: status)
            return false
        }
        return true
    }

    /// Retrieve the PEM bytes, or nil if not set or the Keychain read fails.
    static func get() -> Data? {
        if useTestBacking { return testBacking }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Logged on change only, so "absent (-25300)" (never stored, or
        // deleted) reads differently from the Keychain refusing the read.
        APNsKeychainLog.noteRead(item: account, status: status)
        if status == errSecSuccess { return result as? Data }
        return nil
    }

    /// Clear the stored key. Used by a future "reset APNs" button.
    @discardableResult
    static func clear() -> Bool {
        if useTestBacking { testBacking = nil; return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            APNsKeychainLog.noteFailure("SecItemDelete", item: account, status: status)
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static var hasKey: Bool { APNsKeyStore.get() != nil }

    // MARK: - Test backing

    /// In-memory stand-in for the Keychain under XCTest, as PINStore and
    /// APNsMetadataStore have. The app-hosted, signed test host can reach the
    /// owner's real login Keychain, and this item is the one secret that cannot
    /// be re-derived: losing it means downloading a new key from Apple.
    nonisolated(unsafe) private static var testBacking: Data?
    private static var useTestBacking: Bool { SingleInstanceGuard.isRunningTests }

    /// Empty the in-memory backing. Does nothing outside XCTest.
    static func wipeForTests() {
        guard useTestBacking else { return }
        testBacking = nil
    }
}
