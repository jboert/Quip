import Foundation
import Observation
import AppKit

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

/// Per-device notification preferences synced from the iOS client via
/// PushPreferencesMessage. Keyed on device token (so two phones attached
/// to the same Mac can have different pause schedules). Default values
/// match the iOS client's defaults — if we've never received a prefs
/// message for a device, we treat it as "allow everything with sound."
struct DevicePushPreferences: Codable, Equatable, Sendable {
    var paused: Bool = false
    var quietHoursStart: Int? = nil   // 0-23, local TZ
    var quietHoursEnd: Int? = nil     // 0-23, local TZ
    var sound: Bool = true
    var foregroundBanner: Bool = false

    static let defaults = DevicePushPreferences()

    /// True if the current wall-clock hour falls inside the quiet-hours
    /// window. Supports both same-day (start < end, e.g. 13-17) and
    /// overnight (start > end, e.g. 22-7) ranges. Returns false when
    /// either bound is nil (quiet hours disabled).
    func isQuietNow(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let start = quietHoursStart, let end = quietHoursEnd else { return false }
        let hour = calendar.component(.hour, from: now)
        if start == end { return false }      // degenerate; treat as disabled
        if start < end { return hour >= start && hour < end }
        // Overnight (e.g. 22→7): inside if hour >= 22 OR hour < 7
        return hour >= start || hour < end
    }
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

    /// Per-device preferences keyed by device token. Persisted to
    /// UserDefaults alongside the device list so preferences survive
    /// restart even if the iOS client doesn't immediately re-send on
    /// reconnect.
    private(set) var preferences: [String: DevicePushPreferences] = [:]

    /// Debounce timestamps — last time we fired a push for a given
    /// `windowId + device.token` pair. Prevents rapid-fire pushes when
    /// terminal state oscillates. Not persisted — a 30s debounce across
    /// a restart is fine to violate.
    private var lastPushTimes: [String: Date] = [:]

    /// Max one push per window per this interval (per device).
    private let debounceInterval: TimeInterval = 30.0

    private static let storageKey = "registeredPushDevices"
    private static let preferencesKey = "registeredPushDevicePreferences"

    init() {
        loadDevices()
        loadPreferences()
    }

    private func loadDevices() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([RegisteredPushDevice].self, from: data) {
            devices = decoded
        }
    }

    private func loadPreferences() {
        guard let data = UserDefaults.standard.data(forKey: Self.preferencesKey) else { return }
        if let decoded = try? JSONDecoder().decode([String: DevicePushPreferences].self, from: data) {
            preferences = decoded
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func persistPreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: Self.preferencesKey)
    }

    /// Update (or insert) prefs for a specific device. No-op if the
    /// token isn't registered — we don't want to accumulate orphan
    /// preference rows for phones that never called registerDevice.
    func updatePreferences(forDevice token: String, prefs: DevicePushPreferences) {
        let normalized = token.uppercased()
        guard devices.contains(where: { $0.token == normalized }) else {
            print("[PushNotificationService] ignoring prefs for unregistered token (prefix=\(normalized.prefix(8)))")
            return
        }
        preferences[normalized] = prefs
        persistPreferences()
    }

    /// Fetch prefs for a device, falling back to hardcoded defaults.
    func preferences(forDevice token: String) -> DevicePushPreferences {
        preferences[token.uppercased()] ?? .defaults
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
            preferences.removeValue(forKey: normalized)
            persist()
            persistPreferences()
        }
    }

    /// Fire a "waiting for input" push to every registered device. Call
    /// this from the Mac's terminal-state transition hook when the window
    /// the phone has selected flips to waiting_for_input.
    ///
    /// The method is intentionally forgiving — it silently no-ops on
    /// missing APNs config, missing key, or no registered devices, so
    /// callers don't have to guard. Log-only diagnostics land in the
    /// Mac console for debugging.
    ///
    /// Debounce: 30s per (windowId, device) pair. Global pause +
    /// quiet-hours + sound toggle honored per device.
    func notifyWaitingForInput(windowId: String, windowName: String, attentionCount: Int) {
        guard !devices.isEmpty else { return }

        let keyId = UserDefaults.standard.string(forKey: "apnsKeyId") ?? ""
        let teamId = UserDefaults.standard.string(forKey: "apnsTeamId") ?? ""
        let bundleId = UserDefaults.standard.string(forKey: "apnsBundleId") ?? "com.quip.QuipiOS"
        guard !keyId.isEmpty, !teamId.isEmpty, !bundleId.isEmpty else {
            print("[PushNotificationService] waiting_for_input skipped — APNs not configured in Settings → Notifications")
            return
        }

        let client: APNsClient
        do {
            client = try APNsClient(keyId: keyId, teamId: teamId, bundleId: bundleId)
        } catch {
            print("[PushNotificationService] APNsClient init failed: \(error)")
            return
        }

        let devicesSnapshot = devices
        let prefsSnapshot = preferences
        let now = Date()

        for device in devicesSnapshot {
            let prefs = prefsSnapshot[device.token] ?? .defaults
            if prefs.paused {
                continue
            }
            if prefs.isQuietNow(now: now) {
                continue
            }
            // Per (windowId, device) debounce
            let debounceKey = "\(windowId)|\(device.token)"
            if let last = lastPushTimes[debounceKey], now.timeIntervalSince(last) < debounceInterval {
                continue
            }
            lastPushTimes[debounceKey] = now

            var aps: [String: Any] = [
                "alert": [
                    "title": "Quip",
                    "body": "\(windowName) is waiting for input"
                ],
                "badge": attentionCount
            ]
            if prefs.sound { aps["sound"] = "default" }

            let payload: [String: Any] = [
                "aps": aps,
                "quip_window_id": windowId,
                "quip_event": "waiting_for_input"
            ]

            // Encode now (on main) so the Task below captures Sendable Data
            // instead of an [String: Any] which is not Sendable.
            guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                print("[PushNotificationService] could not encode payload for \(windowId)")
                continue
            }

            // Fire-and-forget send. Each device gets its own Task so a slow
            // or failed one doesn't block the others.
            let capturedClient = client
            let capturedDevice = device
            let capturedToken = capturedDevice.token
            Task {
                do {
                    try await capturedClient.send(payloadData: payloadData, toDevice: capturedDevice)
                    print("[PushNotificationService] push sent to \(capturedToken.prefix(8))… for \(windowId)")
                } catch APNsError.unregistered {
                    await MainActor.run {
                        self.removeDevice(token: capturedToken)
                    }
                } catch {
                    print("[PushNotificationService] push failed for \(capturedToken.prefix(8))…: \(error)")
                }
            }
        }
    }
}
