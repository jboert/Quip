import Foundation
import Observation
import AppKit

/// Append a timestamped line to `LogPaths.pushPath` AND route through
/// NSLog. print()/NSLog disappear when the .app is launched via `open`
/// (stderr goes nowhere user-visible), so for the push pipeline — which
/// is what users actually want to debug when "I didn't get a
/// notification" happens — we commit to a predictable file. Safe to
/// tail while the app is running. Internal so the APNs Keychain stores
/// (`APNsKeychainLog`) can report into the same file.
func quipPushLog(_ message: String) {
    NSLog("[PushNotif] %@", message)
    let line = "\(Date().ISO8601Format()) \(message)\n"
    if let data = line.data(using: .utf8) {
        let path = LogPaths.pushPath
        LogPaths.rotateIfNeeded(path: path)
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
    /// (wishlist §15.) Notify on EVERY enabled window's
    /// `waiting_for_input`, not just the selected one. Defaults false to
    /// preserve the existing "no flood from background Claudes" behavior.
    var notifyAllWindows: Bool = false
    /// Q-56: the push body is the question the prompt asks. Off by default:
    /// prompt text can quote the user's own files.
    var showPromptText: Bool = false

    static let defaults = DevicePushPreferences()

    /// Custom decoder that defaults every field if missing. Without this,
    /// Codable synthesis REQUIRES every non-Optional field; if a future
    /// release adds another `var foo: Bool = false`, every prefs row
    /// stored under the prior schema fails to decode and the in-memory
    /// `preferences` map silently goes empty (because `loadPreferences`
    /// swallows the error via `try?`). Symptom: user's "Pause All"
    /// toggle stops taking effect on the Mac side after a Mac upgrade
    /// — Mac falls back to `.defaults` which has paused=false.
    /// Discovered when §15 added `notifyAllWindows`: prior pause prefs
    /// were unloadable, every push fired, Watch mirrored the alerts.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        self.quietHoursStart = try c.decodeIfPresent(Int.self, forKey: .quietHoursStart)
        self.quietHoursEnd = try c.decodeIfPresent(Int.self, forKey: .quietHoursEnd)
        self.sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
        self.foregroundBanner = try c.decodeIfPresent(Bool.self, forKey: .foregroundBanner) ?? false
        self.bannerEnabled = try c.decodeIfPresent(Bool.self, forKey: .bannerEnabled) ?? true
        self.timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        self.notifyAllWindows = try c.decodeIfPresent(Bool.self, forKey: .notifyAllWindows) ?? false
        self.showPromptText = try c.decodeIfPresent(Bool.self, forKey: .showPromptText) ?? false
    }

    init(paused: Bool = false,
         quietHoursStart: Int? = nil,
         quietHoursEnd: Int? = nil,
         sound: Bool = true,
         foregroundBanner: Bool = false,
         bannerEnabled: Bool = true,
         timeZone: String? = nil,
         notifyAllWindows: Bool = false,
         showPromptText: Bool = false) {
        self.paused = paused
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.sound = sound
        self.foregroundBanner = foregroundBanner
        self.bannerEnabled = bannerEnabled
        self.timeZone = timeZone
        self.notifyAllWindows = notifyAllWindows
        self.showPromptText = showPromptText
    }

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

    /// Where the device registry and per-device prefs persist.
    private let defaults: UserDefaults

    /// `.standard` in the app. Under XCTest a throwaway suite: the Mac suite is
    /// app-hosted with the real bundle id, so `.standard` there IS the owner's
    /// com.quip.mac domain, and the registry tests used to add and remove
    /// tokens (ROUNDTRIP…, REMOVEME, DEDUPTOKEN) in the owner's live
    /// `registeredPushDevices` list.
    nonisolated static var defaultStore: UserDefaults { TestSafeDefaults.store("push") }

    init(defaults: UserDefaults = PushNotificationService.defaultStore) {
        self.defaults = defaults
        loadDevices()
        loadPreferences()
    }

    /// The APNs metadata fields that are empty, in a fixed order. Named in the
    /// "not configured" skip line so push.log says what to fill in.
    nonisolated static func missingAPNsFields(keyId: String, teamId: String, bundleId: String) -> [String] {
        var missing: [String] = []
        if keyId.isEmpty { missing.append("keyId") }
        if teamId.isEmpty { missing.append("teamId") }
        if bundleId.isEmpty { missing.append("bundleId") }
        return missing
    }

    /// The same check in the words Settings → Notifications uses, with the
    /// auth key included: what the phone and the menubar name as missing.
    nonisolated static func missingAPNsSetup(hasKey: Bool, keyId: String, teamId: String, bundleId: String) -> [String] {
        var missing: [String] = []
        if !hasKey { missing.append("auth key") }
        if keyId.isEmpty { missing.append("Key ID") }
        if teamId.isEmpty { missing.append("Team ID") }
        if bundleId.isEmpty { missing.append("Bundle ID") }
        return missing
    }

    /// Read from the stores: empty when a push can go out.
    nonisolated static func currentMissingAPNsSetup() -> [String] {
        missingAPNsSetup(hasKey: APNsKeyStore.hasKey, keyId: APNsMetadataStore.keyId,
                         teamId: APNsMetadataStore.teamId, bundleId: APNsMetadataStore.bundleId)
    }

    /// The push.log line for an event skipped because APNs is not configured.
    nonisolated static func notConfiguredSkipLine(event: String, missing: [String]) -> String {
        "\(event) skipped — APNs not configured (missing: \(missing.joined(separator: ", "))) in Settings → Notifications"
    }

    /// Pure decode seam for the persisted device list.
    ///
    /// Returns the decoded value, or `nil` plus a human-readable reason. The
    /// reason exists because the failure is otherwise invisible: a blob that
    /// won't decode leaves `devices` empty, and an empty device list makes
    /// every `notify*` path take its `guard !devices.isEmpty else { return }`
    /// exit. Push goes 100% silent and nothing anywhere says why.
    nonisolated static func decodeDevices(
        _ data: Data
    ) -> (value: [RegisteredPushDevice]?, failure: String?) {
        do {
            return (try JSONDecoder().decode([RegisteredPushDevice].self, from: data), nil)
        } catch {
            return (nil, "\(data.count) stored bytes failed to decode: \(error)")
        }
    }

    /// Pure decode seam for the persisted per-device preferences map.
    ///
    /// See `DevicePushPreferences.init(from:)` — a schema change once made
    /// every prior prefs row unreadable here. The custom decoder defends
    /// against *missing* fields, but a type change or a corrupt blob still
    /// throws, and the old `try?` turned that into a silent fallback to
    /// `.defaults` (paused=false) — i.e. "Pause All" stops working and push
    /// fires anyway. Report it instead of guessing.
    nonisolated static func decodePreferences(
        _ data: Data
    ) -> (value: [String: DevicePushPreferences]?, failure: String?) {
        do {
            return (try JSONDecoder().decode([String: DevicePushPreferences].self, from: data), nil)
        } catch {
            return (nil, "\(data.count) stored bytes failed to decode: \(error)")
        }
    }

    private func loadDevices() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        let (decoded, failure) = Self.decodeDevices(data)
        if let decoded {
            devices = decoded
        } else if let failure {
            QuipLog.write(
                severity: .error, subsystem: "push",
                message: "loadDevices FAILED — \(failure). No devices registered in memory, "
                       + "so every push will be silently skipped until a device re-registers.",
                to: LogPaths.pushPath
            )
        }
    }

    private func loadPreferences() {
        guard let data = defaults.data(forKey: Self.preferencesKey) else { return }
        let (decoded, failure) = Self.decodePreferences(data)
        if let decoded {
            preferences = decoded
        } else if let failure {
            QuipLog.write(
                severity: .error, subsystem: "push",
                message: "loadPreferences FAILED — \(failure). Falling back to defaults "
                       + "(paused=false), so 'Pause All' and quiet hours will NOT be honored.",
                to: LogPaths.pushPath
            )
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(devices)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            quipPushLog("PERSIST FAILED — devices encode error: \(error.localizedDescription) (\(devices.count) devices not saved; will be lost on relaunch)")
        }
    }

    private func persistPreferences() {
        do {
            let data = try JSONEncoder().encode(preferences)
            defaults.set(data, forKey: Self.preferencesKey)
        } catch {
            quipPushLog("PERSIST FAILED — preferences encode error: \(error.localizedDescription) (\(preferences.count) prefs entries not saved; will be lost on relaunch)")
        }
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

    /// Forget ALL registered devices + their preferences. Backs the Settings
    /// "Forget All" button. APNs tokens rotate per app reinstall/restore and
    /// the registry dedupes by token (not device), so stale tokens for the
    /// same physical phone accumulate. Clearing lets each phone re-register a
    /// single fresh token on its next authenticated connect — the clean way to
    /// shrink the list down to actually-active devices.
    func removeAllDevices() {
        guard !devices.isEmpty else { return }
        quipPushLog("cleared all \(devices.count) registered devices")
        devices.removeAll()
        preferences.removeAll()
        persist()
        persistPreferences()
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
    /// Map detected prompt options to the APNs notification category whose
    /// registered action set matches (iOS caps inline lock-screen actions at
    /// 4). Anything else is `waiting.text`: a Reply field only, since a
    /// prompt with >4 options, one option or no detected shape has no button
    /// set that is right. Phones that predate `waiting.text` show a plain
    /// banner. (§3.2, Q-57)
    nonisolated static func waitingCategory(options: [Int]?, isYesNo: Bool) -> String {
        if let opts = options, (2...4).contains(opts.count) {
            return "waiting." + opts.map(String.init).joined()
        }
        if isYesNo { return "waiting.yn" }
        return "waiting.text"
    }

    /// A bundle covers several prompts, so no single answer fits: no actions.
    nonisolated static let bundleCategory = "waiting.many"

    /// Build the APNs payload dict — pure for testability (#4). Mirrors the
    /// shape the iOS app expects: `aps.alert/badge/category`, top-level
    /// `quip_window_id` / `quip_event`, and §3.2's optional
    /// `quip_options` + `quip_prompt_fingerprint` only when present.
    nonisolated static func buildPayload(windowId: String, title: String, body: String,
                                         attentionCount: Int, sound: Bool, isYesNo: Bool,
                                         options: [Int]?, promptFingerprint: String?,
                                         windowIds: [String]? = nil, threadId: String? = nil,
                                         interruptionLevel: String? = nil) -> [String: Any] {
        let bundled = (windowIds?.count ?? 1) > 1
        var aps: [String: Any] = [
            "alert": ["title": title, "body": body],
            "badge": attentionCount,
            "category": bundled ? bundleCategory : waitingCategory(options: options, isYesNo: isYesNo)
        ]
        if sound { aps["sound"] = "default" }
        // Q-56: one thread per Mac so the phone stacks these as a group;
        // Yes/No prompts are time-sensitive.
        if let threadId { aps["thread-id"] = threadId }
        if let interruptionLevel { aps["interruption-level"] = interruptionLevel }
        var payload: [String: Any] = [
            "aps": aps,
            "quip_window_id": windowId,
            "quip_event": "waiting_for_input"
        ]
        if let options { payload["quip_options"] = options }
        if let promptFingerprint { payload["quip_prompt_fingerprint"] = promptFingerprint }
        // Every window the bundle covers; `quip_window_id` stays the first for
        // phones that predate the field.
        if let windowIds, windowIds.count > 1 { payload["quip_window_ids"] = windowIds }
        return payload
    }

    /// Build the APNs payload for a swrm "story started" event (US-005).
    /// Pure for testability, mirroring `buildPayload`. Distinct from the
    /// waiting_for_input shape: `quip_event` is `swrm_story_started` and the
    /// story id rides in `quip_swrm_task_id` so the iOS push handler can
    /// route/deep-link it independently of terminal-window pushes. No
    /// `badge`/`category` — a story-started alert isn't an attention queue.
    nonisolated static func buildSwrmPayload(project: String, taskId: String,
                                             title: String, sound: Bool) -> [String: Any] {
        var aps: [String: Any] = [
            "alert": ["title": "Started - \(project)", "body": "\(title) -> In Progress"]
        ]
        if sound { aps["sound"] = "default" }
        return [
            "aps": aps,
            "quip_event": "swrm_story_started",
            "quip_swrm_task_id": taskId
        ]
    }

    /// Fire a "story started" push to every registered device (US-005).
    /// Reuses the per-device gating from `notifyWaitingForInput` — paused,
    /// bannerEnabled, quiet-hours — but deliberately drops the
    /// selection/all-windows gate (a swrm event isn't tied to the phone's
    /// selected terminal) and the 30s debounce (story moves are discrete
    /// user actions, and `collapseId` already coalesces repeat moves of the
    /// same story). Best-effort: silent no-op on missing config / no devices.
    func notifySwrmStoryStarted(project: String, taskId: String, title: String) {
        guard !devices.isEmpty else { return }

        let keyId = APNsMetadataStore.keyId
        let teamId = APNsMetadataStore.teamId
        let bundleId = APNsMetadataStore.bundleId
        let missing = Self.missingAPNsFields(keyId: keyId, teamId: teamId, bundleId: bundleId)
        guard missing.isEmpty else {
            quipPushLog(Self.notConfiguredSkipLine(event: "swrm_story_started", missing: missing))
            return
        }

        let client: APNsClient
        do {
            client = try cachedClient(keyId: keyId, teamId: teamId, bundleId: bundleId)
        } catch {
            quipPushLog("APNsClient init failed (swrm): \(error)")
            return
        }

        let devicesSnapshot = devices
        let prefsSnapshot = preferences
        let now = Date()
        // Repeated moves of one story collapse to a single lock-screen alert.
        let collapse = "swrm-\(project)-\(taskId)"

        for device in devicesSnapshot {
            let prefs = prefsSnapshot[device.token] ?? .defaults
            let tokenPrefix = device.token.prefix(8)
            if prefs.paused {
                quipPushLog("skip paused (swrm) — device=\(tokenPrefix) task=\(taskId)")
                continue
            }
            if !prefs.bannerEnabled {
                quipPushLog("skip banner_disabled (swrm) — device=\(tokenPrefix) task=\(taskId)")
                continue
            }
            if prefs.isQuietNow(now: now) {
                let range = "\(prefs.quietHoursStart?.description ?? "nil")-\(prefs.quietHoursEnd?.description ?? "nil")"
                quipPushLog("skip quiet_hours (swrm) — device=\(tokenPrefix) tz=\(prefs.timeZone ?? "mac") range=\(range)")
                continue
            }

            let payload = Self.buildSwrmPayload(
                project: project, taskId: taskId, title: title, sound: prefs.sound)
            // Encode on main → Sendable Data crosses into the Task below.
            guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                quipPushLog("could not encode swrm payload for task=\(taskId)")
                continue
            }

            let capturedClient = client
            let capturedDevice = device
            let capturedToken = capturedDevice.token
            Task {
                do {
                    try await capturedClient.send(
                        payloadData: payloadData,
                        toDevice: capturedDevice,
                        collapseId: collapse
                    )
                    quipPushLog("swrm push sent to \(capturedToken.prefix(8))… task=\(taskId)")
                } catch APNsError.unregistered {
                    await MainActor.run {
                        self.removeDevice(token: capturedToken)
                    }
                } catch {
                    quipPushLog("swrm push failed for \(capturedToken.prefix(8))…: \(error)")
                }
            }
        }
    }

    /// A window is waiting for input. Nothing is sent here: the coalescer
    /// decides when (Q-56: dwell, one push per prompt, siblings bundled) and
    /// `flush` sends. `immediate` skips all of that for the phone's test push.
    func notifyWaitingForInput(windowId: String, windowName: String, projectName: String?,
                               attentionCount: Int, selectedWindowId: String?,
                               options: [Int]? = nil, isYesNo: Bool = false,
                               promptFingerprint: String? = nil, promptPreview: String? = nil,
                               optionLabels: [Int: String]? = nil, immediate: Bool = false) {
        guard !devices.isEmpty else { return }
        lastSelectedWindowId = selectedWindowId
        let wait = PushCoalescer.Wait(windowId: windowId, windowName: windowName, projectName: projectName,
                                      options: options, isYesNo: isYesNo,
                                      promptFingerprint: promptFingerprint, promptPreview: promptPreview,
                                      optionLabels: optionLabels)
        if immediate {
            sendDigest([wait], selectedWindowId: selectedWindowId, now: Date())
            return
        }
        let now = Date()
        if coalescer.waiting(wait, at: now) {
            quipPushLog("queued \(windowId) — pushes after \(Int(coalescer.dwell)) s of waiting, siblings within \(Int(coalescer.coalesce)) s share it")
        } else {
            quipPushLog("skip same_prompt — \(windowId) came back with the prompt already pushed")
        }
        scheduleFlush()
    }

    /// The window stopped waiting (its agent went back to work, or it was
    /// answered). A pending push is dropped; a pushed prompt starts its
    /// "worked for N s" clock, after which the same prompt may push again.
    func windowLeftWaiting(_ windowId: String) {
        coalescer.leftWaiting(windowId, at: Date())
        scheduleFlush()
    }

    func windowClosed(_ windowId: String) {
        coalescer.forget(windowId)
        scheduleFlush()
    }

    // MARK: - Coalescing (Q-56)

    private var coalescer = PushCoalescer()
    private var flushTask: Task<Void, Never>?
    /// The phone's selected window as of the last waiting event; the
    /// "selected window only" filter is applied when the push goes out.
    private var lastSelectedWindowId: String?
    /// One push per device per this many seconds, whatever else happens.
    /// Below dwell + coalesce, so it never spaces the normal flow; it only
    /// stops a burst of immediate (test) pushes.
    private let perDeviceFloor: TimeInterval = 15
    private var lastSendByDevice: [String: Date] = [:]

    private func scheduleFlush() {
        flushTask?.cancel()
        guard let deadline = coalescer.nextDeadline() else { flushTask = nil; return }
        flushTask = Task { @MainActor [weak self] in
            let delay = max(0, deadline.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.flush()
        }
    }

    private func flush() {
        let now = Date()
        let due = coalescer.due(at: now)
        if !due.isEmpty {
            sendDigest(due, selectedWindowId: lastSelectedWindowId, now: now)
        }
        scheduleFlush()
    }

    /// What one push says for the windows it covers. Pure, so tests lock the
    /// wording. With `showPromptText` the single-window body is the question
    /// the prompt asks; otherwise it names the window and says nothing of
    /// the prompt's content.
    nonisolated static func digestText(_ waits: [PushCoalescer.Wait], showPromptText: Bool) -> (title: String, body: String) {
        func label(_ w: PushCoalescer.Wait) -> String {
            if let project = w.projectName, !project.isEmpty { return project }
            return w.windowName
        }
        guard let first = waits.first else { return ("Quip", "Waiting for your answer") }
        if waits.count == 1 {
            let title = label(first)
            var body: String
            if showPromptText, let preview = first.promptPreview, !preview.isEmpty {
                body = preview
            } else if first.windowName != title, !first.windowName.isEmpty {
                body = "\(first.windowName) is waiting for your answer"
            } else {
                body = "Waiting for your answer"
            }
            // The lock-screen buttons can only say "1" / "2"; this line says
            // what they mean. Always shown: it is the answer set, not the
            // question (Q-57).
            if let line = optionsLine(options: first.options, labels: first.optionLabels) {
                body += "\n" + line
            }
            return (title, body)
        }
        var names: [String] = []
        for w in waits {
            let name = label(w)
            if !names.contains(name) { names.append(name) }
        }
        let shown = names.prefix(3).joined(separator: ", ")
        let more = names.count > 3 ? " +\(names.count - 3) more" : ""
        return ("\(waits.count) waiting", shown + more)
    }

    /// `1 Yes · 2 No · 3 Cancel` for the answerable options that have a label,
    /// at most four (the button cap) plus a count of the rest. nil when there
    /// is nothing to say.
    nonisolated static func optionsLine(options: [Int]?, labels: [Int: String]?) -> String? {
        guard let options, let labels, !options.isEmpty else { return nil }
        let labelled = options.compactMap { n in labels[n].map { "\(n) \($0)" } }
        guard !labelled.isEmpty else { return nil }
        let shown = labelled.prefix(4).joined(separator: " · ")
        return labelled.count > 4 ? shown + " +\(labelled.count - 4) more" : shown
    }

    /// Yes/No prompts may break through Focus (time-sensitive, when the app is
    /// entitled; APNs delivers it as active otherwise); everything else is an
    /// ordinary alert.
    nonisolated static func interruptionLevel(for waits: [PushCoalescer.Wait]) -> String {
        waits.contains(where: \.isYesNo) ? "time-sensitive" : "active"
    }

    /// Send one push per device for `waits`, each device seeing only the
    /// windows its preferences allow.
    private func sendDigest(_ waits: [PushCoalescer.Wait], selectedWindowId: String?, now: Date) {
        guard !devices.isEmpty, !waits.isEmpty else { return }

        // GH #22 — APNs metadata moved from UserDefaults to Keychain via
        // APNsMetadataStore. The accessor handles the one-shot migration on
        // first read so existing installs don't need to re-enter values.
        let keyId = APNsMetadataStore.keyId
        let teamId = APNsMetadataStore.teamId
        let bundleId = APNsMetadataStore.bundleId
        let missing = Self.missingAPNsFields(keyId: keyId, teamId: teamId, bundleId: bundleId)
        guard missing.isEmpty else {
            quipPushLog(Self.notConfiguredSkipLine(event: "waiting_for_input", missing: missing))
            return
        }

        let client: APNsClient
        do {
            client = try cachedClient(keyId: keyId, teamId: teamId, bundleId: bundleId)
        } catch {
            quipPushLog("APNsClient init failed: \(error)")
            return
        }

        let threadId = "quip.\(WebSocketServer.deviceID())"
        let devicesSnapshot = devices
        let prefsSnapshot = preferences
        let allIds = waits.map(\.windowId).joined(separator: ",")

        for device in devicesSnapshot {
            let prefs = prefsSnapshot[device.token] ?? .defaults
            let tokenPrefix = device.token.prefix(8)
            // (wishlist §15.) Per-device "all windows" gate. Default false
            // → only the phone's currently-selected window pushes for this
            // device; the user can opt into all-windows in iOS settings.
            let mine = prefs.notifyAllWindows ? waits : waits.filter { $0.windowId == selectedWindowId }
            if mine.isEmpty {
                quipPushLog("skip selection_mismatch — device=\(tokenPrefix) selected=\(selectedWindowId ?? "nil") event=\(allIds)")
                continue
            }
            if prefs.paused {
                quipPushLog("skip paused — device=\(tokenPrefix) windows=\(allIds)")
                continue
            }
            if !prefs.bannerEnabled {
                // Banner disabled in iOS Settings → no APNs push. Live
                // Activity still runs via WebSocket so the island keeps
                // showing thinking/waiting without the alert tray clutter.
                quipPushLog("skip banner_disabled — device=\(tokenPrefix) windows=\(allIds)")
                continue
            }
            if prefs.isQuietNow(now: now) {
                let range = "\(prefs.quietHoursStart?.description ?? "nil")-\(prefs.quietHoursEnd?.description ?? "nil")"
                quipPushLog("skip quiet_hours — device=\(tokenPrefix) tz=\(prefs.timeZone ?? "mac") range=\(range)")
                continue
            }
            if let last = lastSendByDevice[device.token], now.timeIntervalSince(last) < perDeviceFloor {
                quipPushLog("skip device_floor — device=\(tokenPrefix) last=\(Int(now.timeIntervalSince(last)))s ago")
                continue
            }
            lastSendByDevice[device.token] = now

            let text = Self.digestText(mine, showPromptText: prefs.showPromptText)
            let single = mine.count == 1 ? mine[0] : nil
            let payload = Self.buildPayload(
                windowId: mine[0].windowId, title: text.title, body: text.body,
                attentionCount: mine.count, sound: prefs.sound,
                isYesNo: single?.isYesNo ?? false, options: single?.options,
                promptFingerprint: single?.promptFingerprint,
                windowIds: mine.map(\.windowId), threadId: threadId,
                interruptionLevel: Self.interruptionLevel(for: mine)
            )

            // Encode now (on main) so the Task below captures Sendable Data
            // instead of an [String: Any] which is not Sendable.
            guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                quipPushLog("could not encode payload for \(allIds)")
                continue
            }

            // Fire-and-forget send. Each device gets its own Task so a slow
            // or failed one doesn't block the others.
            let capturedClient = client
            let capturedDevice = device
            let capturedToken = capturedDevice.token
            let sentIds = mine.map(\.windowId).joined(separator: ",")
            // (wishlist §15.) One collapse id across waiting pushes, so APNs
            // replaces the unread alert with the latest bundle.
            let collapse = "waiting-batch"
            Task {
                do {
                    try await capturedClient.send(
                        payloadData: payloadData,
                        toDevice: capturedDevice,
                        collapseId: collapse
                    )
                    quipPushLog("push sent to \(capturedToken.prefix(8))… for \(sentIds) (\(mine.count) window\(mine.count == 1 ? "" : "s"))")
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
