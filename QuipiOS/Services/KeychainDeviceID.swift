import Foundation
import Security

/// Stable per-device identifier persisted in the Keychain so it survives
/// app reinstalls — used by the preferences-backup pipeline to key the
/// phone's saved settings on the Mac. UserDefaults can't be used: iOS
/// wipes the app's UserDefaults sandbox on uninstall, defeating the
/// whole point of "remember my settings across reinstall."
///
/// Generated on first access and cached thereafter. Loss of the Keychain
/// item (e.g. user wipes device) means the next install starts fresh —
/// that's acceptable since the Mac's saved snapshot under the old ID
/// becomes unreachable but doesn't actively cause problems.
enum KeychainDeviceID {
    private static let service = "com.quip.QuipiOS"
    private static let account = "device-id"

    static func get() -> String {
        if let existing = read() { return existing }
        let new = UUID().uuidString
        write(new)
        return new
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private static func write(_ value: String) {
        let data = Data(value.utf8)
        // kSecAttrAccessibleAfterFirstUnlock — readable after the first device
        // unlock following boot, which matches when our app actually runs.
        // Critically, items at this level survive app uninstall (unlike
        // ThisDeviceOnly with no subscript, which the system may purge).
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        // Delete any prior entry first so SecItemAdd doesn't fail with duplicate.
        SecItemDelete(attrs as CFDictionary)
        _ = SecItemAdd(attrs as CFDictionary, nil)
    }
}
