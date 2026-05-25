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

    /// (wishlist §15 v2 / Watch-actions path A.) Fired when the user taps
    /// one of the inline notification action buttons (yes / no / 1 / 2)
    /// surfaced via `UNNotificationCategory("waiting_for_input")`.
    /// QuipApp wires this to dispatch a quick_action / send_text over
    /// the active WebSocket so the Mac responds even when the iPhone
    /// (or paired Watch) is locked. Always invoked on main.
    var onActionResponse: ((_ windowId: String, _ action: WaitingActionResponse, _ promptFingerprint: String?) -> Void)?

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
        let fingerprint = userInfo["quip_prompt_fingerprint"] as? String
        let actionId = response.actionIdentifier
        let completion = UncheckedSendable(completionHandler)
        DispatchQueue.main.async { [weak self] in
            guard let self else { completion.value(); return }
            if let action = WaitingActionResponse(actionId: actionId), let windowId {
                self.onActionResponse?(windowId, action, fingerprint)
            } else if let windowId {
                // UNNotificationDefaultActionIdentifier (tap body) or
                // UNNotificationDismissActionIdentifier (swipe away) —
                // tap is the deep-link path, dismiss does nothing.
                if actionId == UNNotificationDefaultActionIdentifier {
                    self.onNotificationTap?(windowId)
                }
            }
            completion.value()
        }
    }
}

/// (wishlist §15 v2 / Watch-actions path A.) Action button identifier set
/// surfaced under the `waiting_for_input` notification category. Each
/// case maps to a discrete Mac-side action so the user can answer a
/// Claude prompt straight from the lock screen — or from the paired
/// Apple Watch, which renders these the same way as the phone.
enum WaitingActionResponse: String, Sendable {
    /// Claude's typical y/n affirmative — fires `quick_action press_y`.
    case yes
    /// Claude's typical y/n negative — fires `quick_action press_n`.
    case no
    /// Numbered-prompt answers — each fires `quick_action select_N` (the Mac
    /// types the digit + Return, with re-validation when a fingerprint is
    /// attached). (§3.2)
    case choiceOne
    case choiceTwo
    case choiceThree
    case choiceFour

    /// Identifier strings used in the `UNNotificationAction` registration
    /// + the `actionIdentifier` we get back on tap.
    var rawIdentifier: String {
        switch self {
        case .yes: return "QUIP_ACTION_YES"
        case .no: return "QUIP_ACTION_NO"
        case .choiceOne: return "QUIP_ACTION_CHOICE_1"
        case .choiceTwo: return "QUIP_ACTION_CHOICE_2"
        case .choiceThree: return "QUIP_ACTION_CHOICE_3"
        case .choiceFour: return "QUIP_ACTION_CHOICE_4"
        }
    }

    /// The `quick_action` wire string this answer dispatches. All numbered
    /// choices unify onto `select_N` so the Mac has a single re-validation
    /// chokepoint. (§3.2)
    var quickAction: String {
        switch self {
        case .yes: return "press_y"
        case .no: return "press_n"
        case .choiceOne: return "select_1"
        case .choiceTwo: return "select_2"
        case .choiceThree: return "select_3"
        case .choiceFour: return "select_4"
        }
    }

    init?(actionId: String) {
        switch actionId {
        case "QUIP_ACTION_YES": self = .yes
        case "QUIP_ACTION_NO": self = .no
        case "QUIP_ACTION_CHOICE_1": self = .choiceOne
        case "QUIP_ACTION_CHOICE_2": self = .choiceTwo
        case "QUIP_ACTION_CHOICE_3": self = .choiceThree
        case "QUIP_ACTION_CHOICE_4": self = .choiceFour
        default: return nil
        }
    }
}

/// Build the `UNNotificationCategory` set Quip registers at launch so the
/// system displays inline action buttons under any push whose payload
/// carries `aps.category == "waiting_for_input"`. (wishlist §15 v2.)
enum WaitingNotificationCategory {
    static let identifier = "waiting_for_input"

    private static func action(_ r: WaitingActionResponse, _ title: String) -> UNNotificationAction {
        UNNotificationAction(identifier: r.rawIdentifier, title: title, options: [])
    }

    /// Numbered-answer actions 1...n (n ≤ 4, the lock-screen cap).
    private static func numberedActions(_ n: Int) -> [UNNotificationAction] {
        let cases: [WaitingActionResponse] = [.choiceOne, .choiceTwo, .choiceThree, .choiceFour]
        return (0..<min(n, 4)).map { action(cases[$0], "\($0 + 1)") }
    }

    /// The full category set Quip registers at launch. The Mac picks the
    /// matching identifier per push (`PushNotificationService.waitingCategory`):
    /// `waiting.yn` / `waiting.12` / `waiting.123` / `waiting.1234`, plus the
    /// legacy `waiting_for_input` (Yes/No/1/2) for old payloads. (§3.2)
    static func makeCategories() -> [UNNotificationCategory] {
        func cat(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
        }
        return [
            cat(identifier, [action(.yes, "Yes"), action(.no, "No"),
                             action(.choiceOne, "1"), action(.choiceTwo, "2")]),
            cat("waiting.yn", [action(.yes, "Yes"), action(.no, "No")]),
            cat("waiting.12", numberedActions(2)),
            cat("waiting.123", numberedActions(3)),
            cat("waiting.1234", numberedActions(4)),
        ]
    }
}

/// Wraps a non-Sendable callback so we can carry it across concurrency
/// domains without Swift 6 complaining. Safe because we only read
/// `.value` on the main queue after a DispatchQueue.main.async hop.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
