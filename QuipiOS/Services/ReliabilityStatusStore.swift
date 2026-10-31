import Foundation

/// Q-90: the latest `reliability_status` each Mac sent, kept per backend so
/// Settings and the "Mac is down" banner can still answer "will my Mac bring
/// Quip back?" while that Mac is unreachable.
enum ReliabilityStatusStore {
    static func key(backendID: String) -> String { "reliability.v1.\(backendID)" }

    static func load(backendID: String, defaults: UserDefaults = .standard) -> ReliabilityStatusMessage? {
        guard let data = defaults.data(forKey: key(backendID: backendID)) else { return nil }
        return try? JSONDecoder().decode(ReliabilityStatusMessage.self, from: data)
    }

    static func save(_ status: ReliabilityStatusMessage, backendID: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        defaults.set(data, forKey: key(backendID: backendID))
    }

    /// The Settings "Auto-restart" row. `warn` renders orange: the Mac will
    /// not bring Quip back, which is worth fixing before leaving the desk.
    static func summary(_ status: ReliabilityStatusMessage?) -> (text: String, warn: Bool) {
        guard let status else { return ("Unknown", false) }
        if status.watching { return ("On", false) }
        return ("Off", true)
    }
}
