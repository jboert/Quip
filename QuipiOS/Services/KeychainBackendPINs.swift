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

    static func read(backendID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: backendID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
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
