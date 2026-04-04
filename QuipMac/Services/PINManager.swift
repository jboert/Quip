// PINManager.swift
// QuipMac — PIN generation and Keychain storage for client authentication

import Foundation
import Security
import Observation

@MainActor
@Observable
final class PINManager {

    var pin: String = ""

    private static let keychainAccount = "com.quip.mac.auth-pin"

    init() {
        if let stored = Self.loadFromKeychain() {
            pin = stored
        } else {
            pin = Self.generateRandomPIN()
            Self.storeInKeychain(pin)
        }
    }

    func regeneratePIN() {
        pin = Self.generateRandomPIN()
        Self.storeInKeychain(pin)
    }

    // MARK: - Private

    private static func generateRandomPIN() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    private static func storeInKeychain(_ pin: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ]
        // Remove any existing entry first
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = pin.data(using: .utf8) ?? Data()
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[PINManager] Keychain store failed: \(status)")
        }
    }

    private static func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let pin = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pin
    }
}
