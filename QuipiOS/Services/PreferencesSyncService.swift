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

    /// Stable device identifier used as the Mac-side storage key.
    let deviceID: String

    init() {
        self.deviceID = KeychainDeviceID.get()
    }

    private var observer: NSObjectProtocol?
    private var kvsObserver: NSObjectProtocol?
    private var debounceWorkItem: DispatchWorkItem?

    /// When non-nil, suppress outbound snapshots until this time. Set
    /// briefly after `applyRestore` so the UserDefaults writes from the
    /// restore don't immediately echo back to the Mac as a "new" snapshot.
    private var suppressUntil: Date = .distantPast

    func start() {
        guard observer == nil else { return }
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
        guard let blob = NSUbiquitousKeyValueStore.default.data(forKey: kvsSnapshotKey),
              let snapshot = try? JSONDecoder().decode(PreferencesSnapshot.self, from: blob)
        else { return }
        applyRestore(snapshot)
    }

    /// Send a `PreferenceRequestMessage` so the Mac can push back any
    /// previously-saved snapshot for this device. Call once per successful
    /// authenticated connect.
    func requestRestore() {
        let msg = PreferenceRequestMessage(deviceID: deviceID)
        guard let data = MessageCoder.encode(msg) else { return }
        send?(data)
    }

    /// Apply a snapshot received from the Mac. Writes to UserDefaults are
    /// the source of truth for the rest of the app — `@AppStorage` views
    /// pick them up automatically. Suppresses the outbound sync briefly
    /// so the writes don't ricochet straight back to the Mac.
    func applyRestore(_ snapshot: PreferencesSnapshot) {
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
        if let v = snapshot.liveActivitiesEnabled { d.set(v, forKey: "liveActivitiesEnabled") }
        if let v = snapshot.ttsEnabled { d.set(v, forKey: "ttsEnabled") }
    }

    private func scheduleSync() {
        guard Date() >= suppressUntil else { return }
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
        if let blob = try? JSONEncoder().encode(snapshot) {
            NSUbiquitousKeyValueStore.default.set(blob, forKey: kvsSnapshotKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        }
        // Then hand to the Mac.
        let msg = PreferenceSnapshotMessage(deviceID: deviceID, preferences: snapshot)
        guard let data = MessageCoder.encode(msg) else { return }
        send?(data)
    }

    /// Read all tracked keys from UserDefaults into a typed snapshot.
    /// Keys the user has never touched stay nil rather than getting
    /// the synthesized defaults from `@AppStorage` — that way the Mac
    /// only stores values the user actually set, and a restore won't
    /// stomp on a default that may have changed in a later app version.
    private func currentSnapshot() -> PreferencesSnapshot {
        let d = UserDefaults.standard
        return PreferencesSnapshot(
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
            liveActivitiesEnabled: d.object(forKey: "liveActivitiesEnabled") as? Bool,
            ttsEnabled: d.object(forKey: "ttsEnabled") as? Bool
        )
    }
}
