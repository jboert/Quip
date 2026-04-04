// PINManager.swift
// QuipMac — PIN generation and storage for client authentication

import Foundation
import Observation

@MainActor
@Observable
final class PINManager {

    var pin: String = ""

    private static let defaultsKey = "QuipAuthPIN"

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.defaultsKey), !stored.isEmpty {
            pin = stored
        } else {
            pin = Self.generateRandomPIN()
            UserDefaults.standard.set(pin, forKey: Self.defaultsKey)
        }
    }

    func regeneratePIN() {
        pin = Self.generateRandomPIN()
        UserDefaults.standard.set(pin, forKey: Self.defaultsKey)
    }

    func savePIN() {
        UserDefaults.standard.set(pin, forKey: Self.defaultsKey)
    }

    // MARK: - Private

    private static func generateRandomPIN() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }
}
