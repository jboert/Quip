import Foundation
import Observation

/// A single iOS device registered to receive pushes from this Mac.
/// Keyed on the APNs device token (uppercase hex). `environment` matches
/// the aps-environment entitlement the iOS app was signed with — a
/// dev-env token won't work against production APNs, so we route per-
/// device at send time using this field.
struct RegisteredPushDevice: Codable, Equatable, Sendable {
    let token: String
    let environment: String
    let registeredAt: Date
}

/// Persistent store for registered iOS device tokens + the plumbing
/// that keeps them deduped and queryable. Sending pushes, JWT signing,
/// and APNs HTTP/2 POSTs live in US-002's `APNsClient` and the wiring
/// in `QuipMacApp.swift` — this class is just the device registry.
///
/// @MainActor is fine for this — registration is low-frequency (once
/// per iOS reconnect) and all callers live on main anyway.
@MainActor
@Observable
final class PushNotificationService {
    /// Every iOS device currently registered to receive pushes. Ordered
    /// by `registeredAt` ascending (oldest first); iteration order isn't
    /// load-bearing, but stable ordering makes the Mac Settings list
    /// predictable to debug.
    private(set) var devices: [RegisteredPushDevice] = []

    private static let storageKey = "registeredPushDevices"

    init() {
        loadDevices()
    }

    private func loadDevices() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([RegisteredPushDevice].self, from: data) {
            devices = decoded
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Add or refresh a device. De-duped by token (same token re-registered
    /// just updates `registeredAt` and `environment` in case the iOS app
    /// rebuilt with a different entitlement).
    func registerDevice(token: String, environment: String) {
        let normalized = token.uppercased()
        guard !normalized.isEmpty else { return }
        if let existingIndex = devices.firstIndex(where: { $0.token == normalized }) {
            devices[existingIndex] = RegisteredPushDevice(
                token: normalized,
                environment: environment,
                registeredAt: Date()
            )
        } else {
            devices.append(RegisteredPushDevice(
                token: normalized,
                environment: environment,
                registeredAt: Date()
            ))
            print("[PushNotificationService] registered new device (prefix=\(normalized.prefix(8)))")
        }
        persist()
    }

    /// Drop a device. Called on APNs 410/BadDeviceToken responses (the iOS
    /// app was uninstalled or notifications turned off) and from manual
    /// "forget this device" UI if we ever add it.
    func removeDevice(token: String) {
        let normalized = token.uppercased()
        let before = devices.count
        devices.removeAll { $0.token == normalized }
        if devices.count != before {
            print("[PushNotificationService] removed device (prefix=\(normalized.prefix(8)))")
            persist()
        }
    }
}
