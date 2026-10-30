import Foundation

/// Q-88 US-009: after time away, open on a window that is asking you
/// something, not only one that is idle.
///
/// "Waiting" alone is not enough: an agent idle at its prompt is
/// `waiting_for_input` too (see the Q-89 fix). So a window qualifies only
/// when it is waiting AND its screen shows a question. The phone lands as
/// usual first (restore, recency), asks the Mac for the screens of the other
/// waiting windows, then jumps if one of them asks something, with a Back
/// toast.
enum SmartLanding {
    /// Away at least this long before a jump is considered.
    static let threshold: TimeInterval = 120
    /// The setting ("Jump to waiting windows"), default on.
    static let enabledKey = "smartLanding.enabled"
    /// Screens to ask the Mac for, at most.
    static let maxProbes = 4
    /// How long to wait for those screens before deciding.
    static let probeWait: TimeInterval = 1.2

    /// `threshold`, or `-QuipSmartLandingAfter <seconds>` in DEBUG builds (S9).
    static var thresholdNow: TimeInterval {
        #if DEBUG
        let override = UserDefaults.standard.double(forKey: "QuipSmartLandingAfter")
        if override > 0 { return override }
        #endif
        return threshold
    }

    struct Candidate: Equatable {
        let id: String
        let isWaiting: Bool
        let isAgent: Bool
        /// The screen, when the phone has it.
        let content: String?
    }

    /// Whether to look at all. Explicit intent (a push tap, a link, a tap)
    /// and "follow the Mac" always win (Q-88 §3).
    static func shouldTry(away: TimeInterval?, enabled: Bool, followFrontmost: Bool,
                          explicit: Bool, threshold: TimeInterval = thresholdNow) -> Bool {
        guard enabled, !followFrontmost, !explicit, let away else { return false }
        return away >= threshold
    }

    /// The windows whose screens to ask for: waiting, not the current one,
    /// most recent first.
    static func probes(current: String?, windows: [Candidate], recency: [String]) -> [String] {
        ordered(windows.filter { $0.isWaiting && $0.id != current }, recency: recency)
            .prefix(maxProbes).map(\.id)
    }

    /// The window to jump to, or nil to stay. Stays when the current window
    /// is itself asking something.
    static func pick(current: String?, windows: [Candidate], recency: [String]) -> String? {
        let asking = windows.filter { $0.isWaiting && asksSomething($0.content ?? "", isAgent: $0.isAgent) }
        if asking.contains(where: { $0.id == current }) { return nil }
        return ordered(asking, recency: recency).first?.id
    }

    /// A question on screen: numbered or bracketed options, a Yes/No arrow
    /// menu, or (outside an agent, where a reply often ends in "?") a last
    /// line that asks.
    static func asksSomething(_ content: String, isAgent: Bool) -> Bool {
        if let options = NumberedPromptDetector.answerableOptions(in: content), options.count >= 2 { return true }
        if let tokens = NumberedPromptDetector.detectInlineOptions(in: content), tokens.count >= 2 { return true }
        if ArrowMenu.isYesNoMenu(in: content) { return true }
        guard !isAgent else { return false }
        let last = content.components(separatedBy: "\n")
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
        return last?.hasSuffix("?") ?? false
    }

    /// Most recent first; the rest keep the Mac's order.
    private static func ordered(_ windows: [Candidate], recency: [String]) -> [Candidate] {
        let rank = Dictionary(recency.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return windows.enumerated().sorted {
            let a = rank[$0.element.id] ?? Int.max, b = rank[$1.element.id] ?? Int.max
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }
}
