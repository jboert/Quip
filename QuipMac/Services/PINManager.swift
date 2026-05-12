// PINManager.swift
// QuipMac — observable wrapper around the Keychain-backed PIN store.

import Foundation
import Observation

@MainActor
@Observable
final class PINManager {

    var pin: String = ""

    /// Number of digits for newly-generated PINs. 8 digits = ~27 bits of
    /// entropy = 100M combos. With AuthThrottle (10 fails → 15min lockout,
    /// per-attempt delay), brute-force at one host is on the order of
    /// centuries. Existing 6-digit PINs from the UserDefaults era are
    /// preserved on migration; only fresh installs and `regeneratePIN()`
    /// produce 8-digit PINs. (GH #14.)
    static let pinDigits = 8

    init() {
        if let stored = PINStore.pin, !stored.isEmpty {
            pin = stored
        } else {
            pin = Self.generateRandomPIN()
            PINStore.pin = pin
        }
    }

    func regeneratePIN() {
        pin = Self.generateRandomPIN()
        PINStore.pin = pin
    }

    func savePIN() {
        PINStore.pin = pin
    }

    // MARK: - Private

    private static func generateRandomPIN() -> String {
        let upper = Int(pow(10.0, Double(pinDigits)))
        return String(format: "%0\(pinDigits)d", Int.random(in: 0..<upper))
    }
}
