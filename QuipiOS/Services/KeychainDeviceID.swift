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

    /// `get()` is reached from `sendSelfIdentity()`, which runs after EVERY
    /// reconnect — and a Keychain that won't read (still locked at launch,
    /// entitlement lost across a resign) stays that way. Latch on the status so
    /// the failure is reported once per distinct cause rather than once per
    /// reconnect, and re-armed when the status changes or the read recovers.
    static let readLatch = LogLatch()

    static func get() -> String {
        if let existing = read() { return existing }
        let new = UUID().uuidString
        write(new)
        return new
    }

    /// Split out so tests can drive statuses a real Keychain won't produce on
    /// demand (-25308 / -34018). nil when the status is ordinary or latched.
    static func failureLine(status: OSStatus, latch: LogLatch = readLatch) -> String? {
        // As in KeychainBackendPINs: not-found is the ordinary first-launch
        // answer (caller mints and writes a fresh ID). Any OTHER failure used
        // to look identical, which silently REKEYS the device — the Mac then
        // sees a brand-new device, and the phone loses its paired identity and
        // its prefs backup for reasons nothing logged.
        guard status != errSecSuccess, status != errSecItemNotFound else {
            latch.noteSuccess()
            return nil
        }
        let v = latch.verdict(for: "OSStatus=\(status)")
        guard v.shouldLog else { return nil }
        return "[Quip][Keychain] deviceID read FAILED OSStatus=\(status) — a NEW device ID will be minted, breaking pairing continuity" + v.suffix
    }

    private static func read(log: (String) -> Void = { print($0) }) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if let line = failureLine(status: status, latch: readLatch) {
            log(line)
        }
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
