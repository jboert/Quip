import Foundation

extension Notification.Name {
    /// Posted with the toast text when the active Mac reports a new restart.
    static let quipMacRestarted = Notification.Name("quip.macRestarted")
}

/// Q-90 US-004: once a restarted Mac is back, say once why Quip went down.
/// Pure, so the wording and the once-per-restart rule are tested; the last
/// restart shown is kept per backend so a reconnect does not repeat it.
enum RestartToast {
    static func key(backendID: String) -> String { "reliability.lastShownRestart.v1.\(backendID)" }

    static func lastShown(backendID: String, defaults: UserDefaults = .standard) -> Double? {
        defaults.object(forKey: key(backendID: backendID)) as? Double
    }

    static func markShown(_ at: Double, backendID: String, defaults: UserDefaults = .standard) {
        defaults.set(at, forKey: key(backendID: backendID))
    }

    /// True only for a restart newer than the last one shown for this Mac.
    static func isNew(lastShown: Double?, incoming: ReliabilityStatusMessage.LastRestart?) -> Bool {
        guard let incoming else { return false }
        guard let lastShown else { return true }
        return incoming.at > lastShown
    }

    /// "Quip on your Mac restarted after a crash (2:04 pm)".
    static func text(reason: String, at: Double, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: Date(timeIntervalSince1970: at)).lowercased()
        return "Quip on your Mac restarted\(cause(reason)) (\(time))"
    }

    static func logLine(reason: String) -> String { "mac_restarted reason=\(reason)" }

    private static func cause(_ reason: String) -> String {
        switch reason {
        case "crash": " after a crash"
        case "hang": " after it froze"
        case "crash_loop": " after crashing repeatedly"
        case "quit": " after it was quit"
        default: ""
        }
    }
}
