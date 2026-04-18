import Foundation
import UIKit
@preconcurrency import UserNotifications
import Observation

/// Tracks which tracked windows need the user's attention (Claude is
/// waiting for input, banner landed but user hasn't acted yet).
///
/// Used by both the picker UI (pulsing yellow dot + auto front-load) and
/// the badge-count updater. Selecting a window on the phone clears its
/// attention flag on the assumption "if you're looking at it, you're
/// engaged."
///
/// Cleared flag + explicit badge update via a single setter so the
/// sources of truth don't drift.
@MainActor
@Observable
final class WindowAttentionCenter {
    /// Set of tracked windowIds currently flagged as needing attention.
    private(set) var windowsNeedingAttention: Set<String> = []

    func markNeedsAttention(_ windowId: String) {
        guard !windowsNeedingAttention.contains(windowId) else { return }
        windowsNeedingAttention.insert(windowId)
        updateBadge()
    }

    func clearAttention(for windowId: String) {
        guard windowsNeedingAttention.contains(windowId) else { return }
        windowsNeedingAttention.remove(windowId)
        updateBadge()
    }

    /// Called when the user selects any window — the assumption is they
    /// came back to the app and are aware, so clear everything.
    func clearAllAttention() {
        guard !windowsNeedingAttention.isEmpty else { return }
        windowsNeedingAttention.removeAll()
        updateBadge()
    }

    private func updateBadge() {
        let count = windowsNeedingAttention.count
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error {
                // iOS < 16 fallback or permission-denied — non-fatal.
                print("[WindowAttention] setBadgeCount error: \(error.localizedDescription)")
            }
        }
    }
}

/// UNUserNotificationCenterDelegate wiring — converts incoming APNs
/// payloads into app-state changes (attention flag, window selection,
/// input-sheet trigger) and controls whether a banner presents while
/// the app is foreground.
///
/// Closures are invoked via DispatchQueue.main.async since the delegate
/// methods are nonisolated — lets us work around UNNotification not
/// being Sendable while still touching MainActor state.
final class PushNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    /// Closure invoked when a push lands and we determine the user
    /// hasn't already got that window selected. Always on main.
    var onWaitingForInput: ((String) -> Void)?

    /// Closure invoked when the user TAPS a push. Deep-link. Always on main.
    var onNotificationTap: ((String) -> Void)?

    /// Returns whatever the user currently has selected on the phone so
    /// we can decide whether to suppress the banner. Called on main.
    var currentlySelectedWindowId: (() -> String?)?

    /// Reads the user's "banner when foreground" pref. Called on main.
    var foregroundBannerEnabled: (() -> Bool)?

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Extract the Sendable bits off the UNNotification BEFORE hopping
        // so the closure capture is clean across concurrency domains.
        let userInfo = notification.request.content.userInfo
        let windowId = userInfo["quip_window_id"] as? String
        let completion = UncheckedSendable(completionHandler)

        DispatchQueue.main.async { [weak self] in
            guard let self else { completion.value([]); return }
            if let windowId {
                self.onWaitingForInput?(windowId)
            }
            let bannerPref = self.foregroundBannerEnabled?() ?? false
            let selected = self.currentlySelectedWindowId?()
            let shouldShowBanner = bannerPref || (windowId != nil && selected != windowId)
            completion.value(shouldShowBanner ? [.banner, .list, .sound] : [])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let windowId = userInfo["quip_window_id"] as? String
        let completion = UncheckedSendable(completionHandler)
        DispatchQueue.main.async { [weak self] in
            if let windowId { self?.onNotificationTap?(windowId) }
            completion.value()
        }
    }
}

/// Wraps a non-Sendable callback so we can carry it across concurrency
/// domains without Swift 6 complaining. Safe because we only read
/// `.value` on the main queue after a DispatchQueue.main.async hop.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
