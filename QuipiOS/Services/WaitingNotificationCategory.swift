import Foundation
import UserNotifications

// Compiled into the app AND the notification service extension
// (QuipNotificationService): keep it free of app-only symbols.

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
    static let replyActionIdentifier = "QUIP_ACTION_REPLY"
    /// Reply field only: free-text prompts, menus with one or more than four
    /// options, anything the Mac could not shape.
    static let textIdentifier = "waiting.text"
    /// Several prompts in one alert: no single answer fits, so no actions.
    static let bundleIdentifier = "waiting.many"

    static func action(_ r: WaitingActionResponse, _ title: String) -> UNNotificationAction {
        UNNotificationAction(identifier: r.rawIdentifier, title: title, options: [])
    }

    /// Typed answer, sent as `send_text` + Return. Free text runs in a
    /// terminal, so unlike the fixed buttons it requires the phone to be
    /// unlocked first (`.authenticationRequired`): Face ID from the lock
    /// screen, nothing extra when the phone is already open.
    static var reply: UNNotificationAction {
        UNTextInputNotificationAction(identifier: replyActionIdentifier, title: "Reply",
                                      options: [.authenticationRequired],
                                      textInputButtonTitle: "Send", textInputPlaceholder: "Type an answer")
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
        // iOS shows at most four actions; Reply takes the fourth slot where
        // one is free. The legacy set stays for Macs that predate Q-57.
        return [
            cat(identifier, [action(.yes, "Yes"), action(.no, "No"),
                             action(.choiceOne, "1"), action(.choiceTwo, "2")]),
            cat("waiting.yn", [action(.yes, "Yes"), action(.no, "No"), reply]),
            cat("waiting.12", numberedActions(2) + [reply]),
            cat("waiting.123", numberedActions(3) + [reply]),
            cat("waiting.1234", numberedActions(4)),
            cat(textIdentifier, [reply]),
            cat(bundleIdentifier, []),
        ]
    }
}

// MARK: - Q-60: buttons titled with the prompt's own answers

extension WaitingNotificationCategory {
    /// Categories made per alert by the notification service extension, so
    /// the long-press buttons read "Yes / Yes, don't ask again / No" instead
    /// of "1 / 2 / 3". A static category cannot change its titles after
    /// registration, so each distinct label set gets its own identifier.
    static let dynamicPrefix = "waiting.dyn."
    /// How many dynamic categories survive a registration. An alert still
    /// on the lock screen keeps its buttons only while its category exists,
    /// so recent ones are kept; older label sets are rare to answer late.
    static let dynamicKeep = 12

    /// `quip_option_labels` from an APNs payload: option number to text.
    static func labels(from userInfo: [AnyHashable: Any]) -> [Int: String] {
        guard let raw = userInfo["quip_option_labels"] as? [String: String] else { return [:] }
        var out: [Int: String] = [:]
        for (k, v) in raw { if let n = Int(k), !v.isEmpty { out[n] = v } }
        return out
    }

    /// `quip_options` from an APNs payload.
    static func options(from userInfo: [AnyHashable: Any]) -> [Int] {
        (userInfo["quip_options"] as? [Int]) ?? []
    }

    /// The per-alert category, or nil when the static set already fits:
    /// fewer than two or more than four labelled options, or option numbers
    /// outside 1...4 (there is no button for them). Reply rides along while
    /// a slot is free, as in the static set.
    static func dynamicCategory(options: [Int], labels: [Int: String]) -> UNNotificationCategory? {
        let cases: [Int: WaitingActionResponse] = [1: .choiceOne, 2: .choiceTwo, 3: .choiceThree, 4: .choiceFour]
        let labelled = options.sorted().compactMap { n -> (Int, String)? in
            guard let text = labels[n], !text.isEmpty, cases[n] != nil else { return nil }
            return (n, text)
        }
        guard (2...4).contains(labelled.count), labelled.count == options.count else { return nil }
        var actions = labelled.map { n, text in action(cases[n]!, text) }
        if actions.count < 4 { actions.append(reply) }
        let key = labelled.map { "\($0.0)=\($0.1)" }.joined(separator: "|")
        return UNNotificationCategory(identifier: dynamicPrefix + fnv1a(key), actions: actions,
                                      intentIdentifiers: [], options: [])
    }

    /// The set to register: every static category, the dynamic ones already
    /// registered (capped), plus `adding`. Registration replaces the whole
    /// set, so the app and the extension both go through here or one wipes
    /// the other's work.
    static func merged(existing: Set<UNNotificationCategory>,
                       adding: UNNotificationCategory?) -> Set<UNNotificationCategory> {
        var out = Set(makeCategories())
        var dynamic = existing.filter { $0.identifier.hasPrefix(dynamicPrefix) }
        if let adding {
            dynamic = dynamic.filter { $0.identifier != adding.identifier }
            dynamic.insert(adding)
        }
        if dynamic.count > dynamicKeep {
            // No timestamps on a category: drop by identifier, never the newcomer.
            let others = dynamic.filter { $0.identifier != adding?.identifier }
            let room = dynamicKeep - (adding == nil ? 0 : 1)
            let keepIds = Set(others.map(\.identifier).sorted().prefix(room))
            dynamic = dynamic.filter { keepIds.contains($0.identifier) || $0.identifier == adding?.identifier }
        }
        out.formUnion(dynamic)
        return out
    }

    /// Register the merged set. Safe on every launch (the app) and per alert
    /// (the extension); `completion` runs after the set is in place.
    static func register(center: UNUserNotificationCenter = .current(),
                         adding: UNNotificationCategory? = nil,
                         completion: (@Sendable () -> Void)? = nil) {
        center.getNotificationCategories { existing in
            center.setNotificationCategories(merged(existing: existing, adding: adding))
            completion?()
        }
    }

    /// Stable 32-bit FNV-1a as 8 hex digits; `hashValue` changes per launch.
    static func fnv1a(_ text: String) -> String {
        var hash: UInt32 = 0x811C9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return String(format: "%08x", hash)
    }
}
