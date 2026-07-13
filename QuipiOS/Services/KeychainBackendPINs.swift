import Foundation
import Security

/// Per-backend PIN storage, keyed by the daemon's stable device UUID
/// (`DeviceIdentityMessage.deviceID`). Mirrors `KeychainDeviceID`'s pattern
/// but partitions by `account = backendID` so multiple paired backends each
/// get their own PIN.
///
/// `kSecAttrAccessibleAfterFirstUnlock` is required: `BackendConnectionManager`
/// auto-connects every paired backend at app launch and after backgrounding,
/// which can happen before the user interacts with the app — the Keychain
/// needs to be readable in those moments.
enum KeychainBackendPINs {
    private static let service = "com.quip.QuipiOS.backend-pin"

    /// `read` runs on every connect attempt, per backend (up to 4):
    /// `BackendConnectionManager.connect()`, `onAuthRequired`, and
    /// `primePINIfPresent` all re-enter it after every reconnect. Its failure
    /// causes are PERSISTENT — a keychain that's still locked (-25308, the
    /// documented auto-connect-before-first-unlock case) stays locked — so an
    /// unlatched log would print on every attempt, forever.
    ///
    /// Keyed per backend so a broken backend A can't mask backend B's first
    /// failure, and per status so a CHANGED status is re-reported.
    static let readLatch = KeyedLogLatch()

    /// Decide what (if anything) to log for a Keychain status. Split out from
    /// `read` so tests can drive the statuses that are impossible to provoke
    /// against a real Keychain (-25308 / -34018). Returns nil when this status
    /// is ordinary, or already latched.
    static func failureLine(status: OSStatus,
                            backendID: String,
                            latch: KeyedLogLatch = readLatch) -> String? {
        // `errSecItemNotFound` is ORDINARY — this backend simply has no PIN
        // saved. Every other non-success status is a real failure that we used
        // to collapse into the same `nil`, so the caller
        // (`primePINIfPresent`) quietly skipped auth and the phone sat there
        // "connected but not authenticated" with nothing to explain it.
        // -25308 errSecInteractionNotAllowed (keychain still locked) and
        // -34018 errSecMissingEntitlement (access group lost across a resign)
        // are the two that actually bite.
        guard status != errSecSuccess, status != errSecItemNotFound else {
            latch.noteSuccess(for: backendID)
            return nil
        }
        let v = latch.verdict(for: backendID, cause: "OSStatus=\(status)")
        guard v.shouldLog else { return nil }
        return "[Quip][Keychain] PIN read FAILED backend=\(backendID) OSStatus=\(status) — auth will be skipped for this backend" + v.suffix
    }

    static func read(backendID: String, log: (String) -> Void = { print($0) }) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: backendID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if let line = failureLine(status: status, backendID: backendID, latch: readLatch) {
            log(line)
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func write(backendID: String, pin: String) {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: backendID,
            kSecValueData as String: Data(pin.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(attrs as CFDictionary)
        _ = SecItemAdd(attrs as CFDictionary, nil)
    }

    static func delete(backendID: String) {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: backendID,
        ]
        SecItemDelete(attrs as CFDictionary)
    }

    /// Used when the daemon's `device_identity` arrives after the entry was
    /// created with a synthetic id — copy the PIN under the real UUID and drop
    /// the synthetic one.
    static func rekey(from oldID: String, to newID: String) {
        guard oldID != newID, let pin = read(backendID: oldID) else { return }
        write(backendID: newID, pin: pin)
        delete(backendID: oldID)
    }
}
