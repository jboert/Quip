import Foundation
import Observation

// Storage key for the encoded snapshot in NSUbiquitousKeyValueStore. One
// blob (rather than per-key) keeps things atomic — a partial sync to iCloud
// can't leave half the prefs from the new state and half from the old.
private let kvsSnapshotKey = "phonePrefsSnapshot.v1"

/// Mirrors a curated set of UserDefaults keys to the Mac over WebSocket so
/// they can be restored after a reinstall wipes the local sandbox. The
/// service is deliberately one-way at write time (push every change up)
/// and request-response at restore time (ask once on each fresh connect).
///
/// Phase-2 (iCloud KVS) will plug into the same snapshot/apply boundary —
/// just add another sink in `pushSnapshot()` and another source in
/// `applyRestore()`.
@Observable
@MainActor
final class PreferencesSyncService {
    /// Set by the owner to actually transmit the snapshot. Optional so the
    /// service can be wired up before the WebSocket exists.
    var send: ((Data) -> Void)?

    /// Connection memory is MERGED into live state, not written straight to
    /// UserDefaults (loads are overwrite-only, so a blind write would clobber
    /// the currently-connected session). The owner sets these to fold a
    /// restored backup into the running app. Args: (pairedBackendsJSON,
    /// activeBackendID?) and (recentConnectionsJSON).
    var onRestorePaired: ((String, String?) -> Void)?
    var onRestoreRecents: ((String) -> Void)?

    /// Prompt ids that must stay on the owner's devices (`local-only` tag:
    /// VibeCut project prompts). Set by the owner from the cached prompt
    /// library. The iCloud copy of the snapshot never mentions them.
    var localOnlyPromptIDs: () -> Set<String> = { [] }

    /// Stable device identifier used as the Mac-side storage key.
    let deviceID: String

    init() {
        self.deviceID = KeychainDeviceID.get()
    }

    private var observer: NSObjectProtocol?
    private var kvsObserver: NSObjectProtocol?
    private var debounceWorkItem: DispatchWorkItem?

    /// Q-63: when the user last changed a tracked preference here, in unix
    /// seconds. Kept in its own suite so writing it does not re-enter the
    /// `UserDefaults.standard` change observer that drives the sync.
    private static let metaSuite = UserDefaults(suiteName: "com.fintechadventures.quip.prefs-meta")
    private static let localModifiedKey = "prefs.localModifiedAt"
    var localModifiedAt: Double? {
        get { Self.metaSuite?.object(forKey: Self.localModifiedKey) as? Double }
        set { Self.metaSuite?.set(newValue, forKey: Self.localModifiedKey) }
    }

    /// When non-nil, suppress outbound snapshots until this time. Set
    /// briefly after `applyRestore` so the UserDefaults writes from the
    /// restore don't immediately echo back to the Mac as a "new" snapshot.
    private var suppressUntil: Date = .distantPast

    /// The backed-up settings as last seen, stamp left out. `UserDefaults`
    /// posts a change for every key, and the app writes untracked keys all
    /// the time (window order on each layout, the recency stack on each Mac
    /// focus change). Only a change here is the user's edit; anything else
    /// must neither push a snapshot nor move `localModifiedAt`, or a backup
    /// restore after a reinstall is refused as "older than the local edit".
    private var lastTracked: PreferencesSnapshot?

    func start() {
        guard observer == nil else { return }
        lastTracked = Self.trackedPreferences(in: .standard)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            // Hop to MainActor — `addObserver(queue:)` schedules the block on
            // the queue but Swift concurrency needs an explicit Task to
            // satisfy MainActor isolation.
            Task { @MainActor [weak self] in
                self?.scheduleSync()
            }
        }

        // Listen for iCloud-driven changes — fires when another device (or a
        // future install of this app) writes a newer snapshot. We pull it
        // into UserDefaults so the local UI updates without the user having
        // to wait for the Mac round-trip.
        kvsObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hydrateFromICloud()
            }
        }

        // Kick off iCloud sync and pull whatever's already up there. This is
        // the path that fires on first launch after a fresh install — if
        // iCloud has a snapshot, it lands in UserDefaults before the Mac
        // round-trip even starts.
        NSUbiquitousKeyValueStore.default.synchronize()
        hydrateFromICloud()
    }

    func stop() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
        }
        observer = nil
        if let obs = kvsObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        kvsObserver = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    /// Pull the latest snapshot from NSUbiquitousKeyValueStore into local
    /// UserDefaults. Called on launch and whenever iCloud signals an
    /// external change. Goes through `applyRestore` so the same suppression
    /// + write logic handles both Mac-restore and iCloud-restore paths.
    private func hydrateFromICloud() {
        // No blob = nothing has ever synced. Ordinary, stay quiet.
        guard let blob = NSUbiquitousKeyValueStore.default.data(forKey: kvsSnapshotKey) else { return }
        do {
            applyRestore(try JSONDecoder().decode(PreferencesSnapshot.self, from: blob))
        } catch {
            // Schema drift after an app update lands here: the user upgrades,
            // their prefs quietly fail to restore, and nothing says why.
            print("[Quip][Prefs] hydrateFromICloud FAILED bytes=\(blob.count) err=\(error) — iCloud prefs NOT restored")
        }
    }

    /// Send a `PreferenceRequestMessage` so the Mac can push back any
    /// previously-saved snapshot for this device. Call once per successful
    /// authenticated connect.
    func requestRestore() {
        let msg = PreferenceRequestMessage(deviceID: deviceID)
        guard let data = MessageCoder.encode(msg) else {
            print("[Quip][Prefs] requestRestore FAILED: could not encode PreferenceRequestMessage — prefs will NOT be restored from Mac this session")
            return
        }
        send?(data)
    }

    /// Apply a snapshot received from the Mac. Writes to UserDefaults are
    /// the source of truth for the rest of the app — `@AppStorage` views
    /// pick them up automatically. Suppresses the outbound sync briefly
    /// so the writes don't ricochet straight back to the Mac.
    func applyRestore(_ snapshot: PreferencesSnapshot) {
        // Q-63: an older (or unstamped) copy never overwrites an edit made
        // here. Before this, the desktop's copy on every auth and iCloud's at
        // every launch wrote straight through, so a quick row re-ordered a
        // minute ago could come back in its old order.
        guard PreferencesFreshness.shouldApply(snapshotSavedAt: snapshot.savedAt,
                                               localModifiedAt: localModifiedAt) else {
            print("[Quip][Prefs] restore skipped: backup stamp \(snapshot.savedAt.map { String(Int($0)) } ?? "none") is not newer than local edit \(localModifiedAt.map { String(Int($0)) } ?? "none")")
            return
        }
        if let stamp = snapshot.savedAt { localModifiedAt = stamp }
        suppressUntil = Date().addingTimeInterval(2.0)
        let d = UserDefaults.standard
        if let v = snapshot.enabledQuickButtons { d.set(v, forKey: "enabledQuickButtons") }
        if let v = snapshot.tintContentBorder { d.set(v, forKey: "tintContentBorder") }
        if let v = snapshot.contentZoomLevel { d.set(v, forKey: "contentZoomLevel") }
        if let v = snapshot.terminalHeightFraction { d.set(v, forKey: "terminalHeightFraction") }
        if let v = snapshot.terminalWidthFraction { d.set(v, forKey: "terminalWidthFraction") }
        if let v = snapshot.pushPaused { d.set(v, forKey: "pushPaused") }
        if let v = snapshot.pushBannerEnabled { d.set(v, forKey: "pushBannerEnabled") }
        if let v = snapshot.pushSound { d.set(v, forKey: "pushSound") }
        if let v = snapshot.pushForegroundBanner { d.set(v, forKey: "pushForegroundBanner") }
        if let v = snapshot.pushQuietHoursEnabled { d.set(v, forKey: "pushQuietHoursEnabled") }
        if let v = snapshot.pushQuietHoursStart { d.set(v, forKey: "pushQuietHoursStart") }
        if let v = snapshot.pushQuietHoursEnd { d.set(v, forKey: "pushQuietHoursEnd") }
        if let v = snapshot.pushNotifyAllWindows { d.set(v, forKey: "pushNotifyAllWindows") }
        if let v = snapshot.pushShowPromptText { d.set(v, forKey: "pushShowPromptText") }
        if let v = snapshot.liveActivitiesEnabled { d.set(v, forKey: "liveActivitiesEnabled") }
        if let v = snapshot.ttsEnabled { d.set(v, forKey: "ttsEnabled") }
        if let v = snapshot.dictationAutoSend { d.set(v, forKey: "dictation.autoSend") }
        if let v = snapshot.terminalTextSize { d.set(v, forKey: "terminalTextSize") }
        if let v = snapshot.quickSlotsJSON { d.set(v, forKey: "quickSlotsJSON") }
        if let v = snapshot.mainRowOrderJSON { d.set(v, forKey: "mainRowOrderJSON") }
        if let v = snapshot.customButtonsJSON { d.set(v, forKey: "customButtonsJSON") }
        if let v = snapshot.quickSlotColorsJSON { d.set(v, forKey: KeyColors.storageKey) }
        if let v = snapshot.followFrontmost { d.set(v, forKey: "followFrontmost") }
        if let v = snapshot.smartLandingEnabled { d.set(v, forKey: SmartLanding.enabledKey) }
        if let v = snapshot.windowOrderMode, PhoneWindowOrder.Mode(rawValue: v) != nil {
            d.set(v, forKey: PhoneWindowOrder.Mode.storageKey)
        }
        // Connection memory: hand to the merge hooks rather than writing the
        // blob directly (a direct write would clobber the live, overwrite-only
        // paired/recents lists). The hooks union restored rows into running
        // state and re-persist. The suppression window above still covers the
        // savePaired/saveRecents writes they trigger.
        if let v = snapshot.pairedBackendsJSON { onRestorePaired?(v, snapshot.activeBackendID) }
        if let v = snapshot.recentConnectionsJSON { onRestoreRecents?(v) }
        if let v = snapshot.promptUsageJSON {
            // Merge: the live store may hold uses newer than the backup.
            let local = PromptRanker.decode(d.string(forKey: "promptUsageJSON") ?? "{}")
            let merged = PromptRanker.merged(local, with: PromptRanker.decode(v), at: Date())
            if merged != local { d.set(PromptRanker.encode(merged), forKey: "promptUsageJSON") }
        }
    }

    private func scheduleSync() {
        let tracked = Self.trackedPreferences(in: .standard)
        // Writes from a restore become the new baseline, not an edit.
        guard Date() >= suppressUntil else { lastTracked = tracked; return }
        guard tracked != lastTracked else { return }
        lastTracked = tracked
        // A change outside the restore window is the user's own edit.
        localModifiedAt = Date().timeIntervalSince1970
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.pushSnapshot()
            }
        }
        debounceWorkItem = work
        // 0.5s coalesces toggle-bursts (e.g. tapping multiple Quick Button
        // chips in succession) into one upload.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func pushSnapshot() {
        let snapshot = currentSnapshot()
        // Mirror to iCloud first — synchronous local write, async cloud sync.
        // No throttling needed here; NSUbiquitousKeyValueStore handles its
        // own coalescing and throttles writes to roughly once per second
        // internally before pushing to iCloud.
        do {
            // iCloud is not the owner's device alone: strip local-only prompts
            // from the copy that goes there. The Mac keeps the full snapshot.
            let blob = try JSONEncoder().encode(
                Self.scrubbed(snapshot, localOnly: rememberedLocalOnlyIDs()))
            NSUbiquitousKeyValueStore.default.set(blob, forKey: kvsSnapshotKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        } catch {
            print("[Quip][Prefs] pushSnapshot FAILED to encode for iCloud err=\(error) — prefs NOT backed up to iCloud")
        }
        // Then hand to the Mac.
        let msg = PreferenceSnapshotMessage(deviceID: deviceID, preferences: snapshot)
        guard let data = MessageCoder.encode(msg) else {
            print("[Quip][Prefs] pushSnapshot FAILED: could not encode PreferenceSnapshotMessage — prefs NOT backed up to Mac")
            return
        }
        send?(data)
    }

    private static let localOnlyMemoryKey = "prefs.localOnlyPromptIDs"

    /// Current local-only ids united with every one this phone has seen before.
    /// The library cache is empty while the phone is not connected, and a
    /// snapshot written then must still leave those prompts out. Kept in the
    /// meta suite so writing it does not re-enter the change observer.
    private func rememberedLocalOnlyIDs() -> Set<String> {
        let known = Set(Self.metaSuite?.stringArray(forKey: Self.localOnlyMemoryKey) ?? [])
        let all = known.union(localOnlyPromptIDs())
        if all != known { Self.metaSuite?.set(Array(all).sorted(), forKey: Self.localOnlyMemoryKey) }
        return all
    }

    /// `snapshot` without anything that names a local-only prompt: its usage
    /// record, its pinned quick-button slot, and that slot's color. Everything
    /// else in the snapshot is untouched. Pure, so it is tested without iCloud.
    nonisolated static func scrubbed(_ snapshot: PreferencesSnapshot, localOnly: Set<String>) -> PreferencesSnapshot {
        guard !localOnly.isEmpty else { return snapshot }
        var out = snapshot
        if let json = snapshot.promptUsageJSON {
            let store = PromptRanker.decode(json).filter { !localOnly.contains($0.key) }
            out.promptUsageJSON = PromptRanker.encode(store)
        }
        // Edited as plain JSON, not through `QuickSlot`: a slot kind this build
        // cannot decode must pass through untouched, not break the scrub.
        if let json = snapshot.quickSlotsJSON, !json.isEmpty,
           let data = json.data(using: .utf8),
           let slots = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let kept = slots.filter { slot in
                !(slot["kind"] as? String == "prompt"
                  && (slot["promptID"] as? String).map(localOnly.contains) == true)
            }
            if kept.count != slots.count,
               let encoded = try? JSONSerialization.data(withJSONObject: kept),
               let text = String(data: encoded, encoding: .utf8) {
                out.quickSlotsJSON = text
            }
        }
        if let json = snapshot.quickSlotColorsJSON, !json.isEmpty,
           let data = json.data(using: .utf8),
           let colors = try? JSONDecoder().decode([String: String].self, from: data) {
            let kept = colors.filter { key, _ in
                !(key.hasPrefix("p:") && localOnly.contains(String(key.dropFirst(2))))
            }
            if kept.count != colors.count, let encoded = try? JSONEncoder().encode(kept),
               let text = String(data: encoded, encoding: .utf8) {
                out.quickSlotColorsJSON = text
            }
        }
        return out
    }

    /// Read all tracked keys from UserDefaults into a typed snapshot.
    /// Keys the user has never touched stay nil rather than getting
    /// the synthesized defaults from `@AppStorage` — that way the Mac
    /// only stores values the user actually set, and a restore won't
    /// stomp on a default that may have changed in a later app version.
    private func currentSnapshot() -> PreferencesSnapshot {
        Self.snapshot(from: .standard, savedAt: localModifiedAt ?? Date().timeIntervalSince1970)
    }

    /// The backed-up settings in `d` with a fixed stamp: two reads compare
    /// equal exactly when no tracked setting changed between them.
    nonisolated static func trackedPreferences(in d: UserDefaults) -> PreferencesSnapshot {
        snapshot(from: d, savedAt: 0)
    }

    /// The capture itself, on any defaults, so a test can read it back.
    nonisolated static func snapshot(from d: UserDefaults, savedAt: Double) -> PreferencesSnapshot {
        PreferencesSnapshot(
            enabledQuickButtons: d.string(forKey: "enabledQuickButtons"),
            tintContentBorder: d.object(forKey: "tintContentBorder") as? Bool,
            contentZoomLevel: d.object(forKey: "contentZoomLevel") as? Int,
            terminalHeightFraction: d.object(forKey: "terminalHeightFraction") as? Double,
            terminalWidthFraction: d.object(forKey: "terminalWidthFraction") as? Double,
            pushPaused: d.object(forKey: "pushPaused") as? Bool,
            pushBannerEnabled: d.object(forKey: "pushBannerEnabled") as? Bool,
            pushSound: d.object(forKey: "pushSound") as? Bool,
            pushForegroundBanner: d.object(forKey: "pushForegroundBanner") as? Bool,
            pushQuietHoursEnabled: d.object(forKey: "pushQuietHoursEnabled") as? Bool,
            pushQuietHoursStart: d.object(forKey: "pushQuietHoursStart") as? Int,
            pushQuietHoursEnd: d.object(forKey: "pushQuietHoursEnd") as? Int,
            pushNotifyAllWindows: d.object(forKey: "pushNotifyAllWindows") as? Bool,
            pushShowPromptText: d.object(forKey: "pushShowPromptText") as? Bool,
            liveActivitiesEnabled: d.object(forKey: "liveActivitiesEnabled") as? Bool,
            ttsEnabled: d.object(forKey: "ttsEnabled") as? Bool,
            dictationAutoSend: d.object(forKey: "dictation.autoSend") as? Bool,
            terminalTextSize: d.object(forKey: "terminalTextSize") as? Double,
            quickSlotsJSON: d.string(forKey: "quickSlotsJSON"),
            customButtonsJSON: d.string(forKey: "customButtonsJSON"),
            quickSlotColorsJSON: d.string(forKey: KeyColors.storageKey),
            followFrontmost: d.object(forKey: "followFrontmost") as? Bool,
            pairedBackendsJSON: d.data(forKey: "pairedBackendsData").flatMap { String(data: $0, encoding: .utf8) },
            recentConnectionsJSON: d.data(forKey: "recentConnectionsData").flatMap { String(data: $0, encoding: .utf8) },
            activeBackendID: d.string(forKey: "activeBackendID"),
            promptUsageJSON: d.string(forKey: "promptUsageJSON"),
            savedAt: savedAt,
            mainRowOrderJSON: d.string(forKey: "mainRowOrderJSON"),
            windowOrderMode: d.string(forKey: PhoneWindowOrder.Mode.storageKey)
                .flatMap { PhoneWindowOrder.Mode(rawValue: $0)?.rawValue },
            smartLandingEnabled: d.object(forKey: SmartLanding.enabledKey) as? Bool
        )
    }
}
