import Foundation
import Observation
import AppKit

/// Append a timestamped line to `LogPaths.pushPath` AND route through
/// NSLog. print()/NSLog disappear when the .app is launched via `open`
/// (stderr goes nowhere user-visible), so for the push pipeline — which
/// is what users actually want to debug when "I didn't get a
/// notification" happens — we commit to a predictable file. Safe to
/// tail while the app is running.
private func quipPushLog(_ message: String) {
    NSLog("[PushNotif] %@", message)
    let line = "\(Date().ISO8601Format()) \(message)\n"
    if let data = line.data(using: .utf8) {
        let path = LogPaths.pushPath
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

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
    var quietHoursStart: Int? = nil   // 0-23, phone's local TZ
    var quietHoursEnd: Int? = nil     // 0-23, phone's local TZ
    var sound: Bool = true
    var foregroundBanner: Bool = false
    /// Master banner toggle. False = skip the APNs push entirely so no
    /// lock-screen / notification-center alert appears. Live Activities
    /// still run because they're driven by WebSocket state changes, not
    /// APNs. Default true for backwards-compat with existing prefs rows.
    var bannerEnabled: Bool = true
    /// IANA identifier for the phone's TZ at the time prefs were set.
    /// nil = legacy prefs row or legacy client — fall back to the Mac's
    /// own `Calendar.current`, which matches the pre-TZ behavior.
    var timeZone: String? = nil

    static let defaults = DevicePushPreferences()

    /// True if the current wall-clock hour falls inside the quiet-hours
    /// window. Supports both same-day (start < end, e.g. 13-17) and
    /// overnight (start > end, e.g. 22-7) ranges. Returns false when
    /// either bound is nil (quiet hours disabled). Evaluates the hour in
    /// the phone's TZ when known, so "10 PM - 7 AM" means the user's 10
    /// PM even if the Mac is in a different TZ (traveling, remote host).
    func isQuietNow(now: Date = Date()) -> Bool {
        guard let start = quietHoursStart, let end = quietHoursEnd else { return false }
        var calendar = Calendar(identifier: .gregorian)
        if let tzId = timeZone, let parsed = TimeZone(identifier: tzId) {
            calendar.timeZone = parsed
        }
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

    /// Shared APNs client — lifetime of the service so its JWT cache
    /// survives across Test Push clicks + real triggers. APNs rate-
    /// limits new provider tokens to ~1 per 20 minutes per kid; making
    /// a fresh client per send (the old behavior) blew through that
    /// with 2-3 quick Test Push taps → 429 TooManyProviderTokenUpdates.
    /// `sharedClientKey` encodes the keyId+teamId+bundleId the client
    /// was built with — any change to those inputs invalidates and
    /// rebuilds.
    private var sharedClient: APNsClient?
    private var sharedClientKey: String?

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
            quipPushLog("ignoring prefs for unregistered token (prefix=\(normalized.prefix(8)))")
            return
        }
        preferences[normalized] = prefs
        persistPreferences()
    }

    /// Fetch prefs for a device, falling back to hardcoded defaults.
    func preferences(forDevice token: String) -> DevicePushPreferences {
        preferences[token.uppercased()] ?? .defaults
    }

    /// Return (and lazily create) the shared APNsClient for the given
    /// key/team/bundle triple. Reused across Test Push clicks and real
    /// triggers so the JWT stays cached — avoids APNs 429
    /// TooManyProviderTokenUpdates when the user clicks Test Push
    /// several times in a short window.
    ///
    /// If the user changes any of the three inputs in Settings, the
    /// cache key changes and we rebuild the client (new JWT cycle).
    func cachedClient(keyId: String, teamId: String, bundleId: String) throws -> APNsClient {
        let cacheKey = "\(keyId)|\(teamId)|\(bundleId)"
        if let existing = sharedClient, sharedClientKey == cacheKey {
            return existing
        }
        let client = try APNsClient(keyId: keyId, teamId: teamId, bundleId: bundleId)
        sharedClient = client
        sharedClientKey = cacheKey
        return client
    }

    /// Drop the cached client — called if the user edits the .p8 key
    /// via APNsKeyStore.set, since the old client still holds the old
    /// parsed private key in memory.
    func invalidateClient() {
        sharedClient = nil
        sharedClientKey = nil
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
            quipPushLog("registered new device (prefix=\(normalized.prefix(8)))")
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
            quipPushLog("removed device (prefix=\(normalized.prefix(8)))")
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
    func notifyWaitingForInput(windowId: String, windowName: String, projectName: String?, attentionCount: Int) {
        guard !devices.isEmpty else { return }

        let keyId = UserDefaults.standard.string(forKey: "apnsKeyId") ?? ""
        let teamId = UserDefaults.standard.string(forKey: "apnsTeamId") ?? ""
        let bundleId = UserDefaults.standard.string(forKey: "apnsBundleId") ?? "com.quip.QuipiOS"
        guard !keyId.isEmpty, !teamId.isEmpty, !bundleId.isEmpty else {
            quipPushLog("waiting_for_input skipped — APNs not configured in Settings → Notifications")
            return
        }

        let client: APNsClient
        do {
            client = try cachedClient(keyId: keyId, teamId: teamId, bundleId: bundleId)
        } catch {
            quipPushLog("APNsClient init failed: \(error)")
            return
        }

        let devicesSnapshot = devices
        let prefsSnapshot = preferences
        let now = Date()

        for device in devicesSnapshot {
            let prefs = prefsSnapshot[device.token] ?? .defaults
            let tokenPrefix = device.token.prefix(8)
            if prefs.paused {
                quipPushLog("skip paused — device=\(tokenPrefix) window=\(windowId)")
                continue
            }
            if !prefs.bannerEnabled {
                // Banner disabled in iOS Settings → no APNs push. Live
                // Activity still runs via WebSocket so the island keeps
                // showing thinking/waiting without the alert tray clutter.
                quipPushLog("skip banner_disabled — device=\(tokenPrefix) window=\(windowId)")
                continue
            }
            if prefs.isQuietNow(now: now) {
                let range = "\(prefs.quietHoursStart?.description ?? "nil")-\(prefs.quietHoursEnd?.description ?? "nil")"
                quipPushLog("skip quiet_hours — device=\(tokenPrefix) tz=\(prefs.timeZone ?? "mac") range=\(range)")
                continue
            }
            // Per (windowId, device) debounce
            let debounceKey = "\(windowId)|\(device.token)"
            if let last = lastPushTimes[debounceKey], now.timeIntervalSince(last) < debounceInterval {
                let elapsed = String(format: "%.1f", now.timeIntervalSince(last))
                quipPushLog("skip debounce — device=\(tokenPrefix) window=\(windowId) last=\(elapsed)s ago")
                continue
            }
            lastPushTimes[debounceKey] = now

            // Prefer the project (cwd basename like "Quip" or "credit-unions")
            // in the title — that's how users mentally identify which session
            // needs them. Fall back to "Quip" when we don't have a project.
            let title: String
            if let p = projectName, !p.isEmpty {
                title = p
            } else {
                title = "Quip"
            }
            var aps: [String: Any] = [
                "alert": [
                    "title": title,
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
                quipPushLog("could not encode payload for \(windowId)")
                continue
            }

            // Fire-and-forget send. Each device gets its own Task so a slow
            // or failed one doesn't block the others.
            let capturedClient = client
            let capturedDevice = device
            let capturedToken = capturedDevice.token
            let collapse = "waiting-\(windowId)"
            Task {
                do {
                    try await capturedClient.send(
                        payloadData: payloadData,
                        toDevice: capturedDevice,
                        collapseId: collapse
                    )
                    quipPushLog("push sent to \(capturedToken.prefix(8))… for \(windowId)")
                } catch APNsError.unregistered {
                    await MainActor.run {
                        self.removeDevice(token: capturedToken)
                    }
                } catch {
                    quipPushLog("push failed for \(capturedToken.prefix(8))…: \(error)")
                }
            }
        }
    }
}
