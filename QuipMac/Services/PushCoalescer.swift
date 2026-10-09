import Foundation

/// When a waiting window becomes a push, and which windows ride in the same
/// one (board Q-56). A pure state machine: `PushNotificationService` owns
/// the clock and the sending.
///
/// Three rules, each measured against one day of push.log (2026-10-08,
/// 1713 waiting episodes, 118 pushes in 80 minutes):
/// - **dwell**: a window must wait `dwell` seconds without interruption
///   before it counts. A quarter of today's episodes lasted under 6 s: the
///   agent blocked on the network, not a prompt.
/// - **one push per prompt**: a window that left waiting and came back with
///   the same prompt within `rework` seconds is the same episode and does not
///   push again. A different prompt (fingerprint) or `rework` seconds of work
///   in between starts a new one.
/// - **coalesce**: after the first window is due, wait `coalesce` seconds so
///   siblings join; one push lists them all.
struct PushCoalescer {
    struct Wait: Equatable, Sendable {
        var windowId: String
        var windowName: String
        var projectName: String?
        var options: [Int]?
        var isYesNo: Bool
        var promptFingerprint: String?
        var promptPreview: String?
        /// Option text by number, for the body line under the question
        /// (`1 Yes · 2 No`). nil when the prompt has no numbered options.
        var optionLabels: [Int: String]? = nil
        /// "Claude" / "Codex" … for the alert's subtitle; nil for a shell.
        var agentName: String? = nil
    }

    var dwell: TimeInterval = 10
    var coalesce: TimeInterval = 8
    var rework: TimeInterval = 30
    /// Episodes older than this are forgotten.
    var episodeMemory: TimeInterval = 3600

    private struct Pending { var wait: Wait; var since: Date }
    private struct Episode { var fingerprint: String?; var pushedAt: Date; var leftAt: Date? }
    private var pending: [String: Pending] = [:]
    private var episodes: [String: Episode] = [:]

    var pendingWindowIDs: [String] { pending.keys.sorted() }

    /// A window entered waiting, or reported it again with fresher details.
    /// Returns false when this is the same prompt as the last push.
    @discardableResult
    mutating func waiting(_ wait: Wait, at now: Date) -> Bool {
        if var current = pending[wait.windowId] {
            current.wait = wait
            pending[wait.windowId] = current
            return true
        }
        if let episode = episodes[wait.windowId], episode.fingerprint == wait.promptFingerprint {
            let worked = episode.leftAt.map { now.timeIntervalSince($0) } ?? 0
            if worked < rework { return false }
        }
        pending[wait.windowId] = Pending(wait: wait, since: now)
        return true
    }

    /// The window stopped waiting: a pending one is dropped, a pushed one
    /// remembers when its agent went back to work.
    mutating func leftWaiting(_ windowId: String, at now: Date) {
        pending[windowId] = nil
        if var episode = episodes[windowId], episode.leftAt == nil {
            episode.leftAt = now
            episodes[windowId] = episode
        }
    }

    mutating func forget(_ windowId: String) {
        pending[windowId] = nil
        episodes[windowId] = nil
    }

    /// When `due(at:)` can next return something; nil while nothing waits.
    func nextDeadline() -> Date? {
        pending.values.map(\.since).min()?.addingTimeInterval(dwell + coalesce)
    }

    /// The windows to push now, oldest first, or empty before the deadline.
    /// Each returned window starts an episode; it will not push again for
    /// the same prompt.
    mutating func due(at now: Date) -> [Wait] {
        episodes = episodes.filter { now.timeIntervalSince($0.value.pushedAt) < episodeMemory }
        guard let deadline = nextDeadline(), now >= deadline else { return [] }
        let ready = pending.values
            .filter { now.timeIntervalSince($0.since) >= dwell }
            .sorted { $0.since < $1.since }
        for item in ready {
            pending[item.wait.windowId] = nil
            episodes[item.wait.windowId] = Episode(fingerprint: item.wait.promptFingerprint, pushedAt: now, leftAt: nil)
        }
        return ready.map(\.wait)
    }
}
