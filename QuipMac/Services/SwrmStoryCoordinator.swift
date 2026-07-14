// SwrmStoryCoordinator.swift
// QuipMac — the single fan-out point for the swrm "story started" trigger.
//
// SwrmProjectStore runs one SwrmEventTailer per configured project root and
// surfaces their parsed events through `onTailerEvents` (US-002 seam). This
// coordinator is what that seam is wired to: it applies the pure trigger
// predicate (`SwrmEvent.isStoryStarted`, US-004) and, for each match, fires
// the user-facing side-effects.
//
// US-004 scope: broadcast a phone card over WebSocket. Later stories hang
// additional best-effort side-effects off this SAME trigger:
//   - US-005: an APNs push to registered devices
//   - US-007: a notice line injected into the matching iTerm session
// Each side-effect is independent and best-effort — one failing must not
// suppress the others. Lifecycle wiring (start/stop, first-launch cursor
// seed) is US-008.

import Foundation

@MainActor
final class SwrmStoryCoordinator {

    /// The Mac's WebSocket server. Weak: the coordinator never owns it — the
    /// app scene does — and must not keep it alive past teardown.
    weak var webSocketServer: WebSocketServer?

    /// The push registry/sender (US-005). Weak for the same reason — owned by
    /// the app scene. When nil (not yet wired), the push side-effect no-ops.
    weak var pushNotificationService: PushNotificationService?

    /// Window registry (US-007). Used to find the terminal whose working
    /// directory is the started story's project root. Weak — owned by the app
    /// scene. When nil, the inject side-effect no-ops.
    weak var windowManager: WindowManager?

    /// Keystroke path into terminals (US-007). iTerm2-only: the session-id
    /// write path lands text in the exact session without stealing focus. Weak
    /// — owned by the app scene. When nil, the inject side-effect no-ops.
    weak var keystrokeInjector: KeystrokeInjector?

    init(webSocketServer: WebSocketServer? = nil,
         pushNotificationService: PushNotificationService? = nil,
         windowManager: WindowManager? = nil,
         keystrokeInjector: KeystrokeInjector? = nil) {
        self.webSocketServer = webSocketServer
        self.pushNotificationService = pushNotificationService
        self.windowManager = windowManager
        self.keystrokeInjector = keystrokeInjector
    }

    /// Wired to `SwrmProjectStore.onTailerEvents`. Filters a tailer's freshly
    /// delivered batch down to "story started" events and fans each out.
    func handle(tailer: SwrmEventTailer, events: [SwrmEvent]) {
        for event in events where event.isStoryStarted {
            handleStoryStarted(tailer: tailer, event: event)
        }
    }

    private func handleStoryStarted(tailer: SwrmEventTailer, event: SwrmEvent) {
        // Title comes from the tailer's file-only cache (US-003); falls back
        // to "Story #<id>" when still unknown — never blank, never crashes.
        let title = tailer.resolvedTitle(forAggregateID: event.aggregateID)
        let project = projectName(for: tailer, event: event)
        SwrmEventTailer.globalLog(
            "trigger: story started project=\(project) task=\(event.aggregateID) title=\(title)")

        // US-004 — phone card over WebSocket (best-effort; broadcast no-ops
        // when no phones are connected/authenticated).
        let card = SwrmStoryStartedMessage(
            project: project, taskId: event.aggregateID, title: title, ts: event.ts)
        webSocketServer?.broadcast(card)

        // US-005 — APNs push so the alert lands even when Quip is
        // backgrounded. Independent + best-effort: the registry no-ops on
        // missing APNs config / no registered devices, and a send failure on
        // one device never suppresses the card above or the other devices.
        pushNotificationService?.notifySwrmStoryStarted(
            project: project, taskId: event.aggregateID, title: title)

        // US-007 — echo an unsubmitted notice line into the iTerm session whose
        // cwd is the project root. Independent + best-effort: no match / no
        // session id just logs and skips, never affecting the card or push.
        injectNotice(rootPath: tailer.projectRoot.path,
                     taskId: event.aggregateID, title: title)
    }

    /// Prefer the event's own `project` label; fall back to the root folder
    /// name so the card always shows something human-readable.
    private func projectName(for tailer: SwrmEventTailer, event: SwrmEvent) -> String {
        if let p = event.project, !p.isEmpty { return p }
        return tailer.projectRoot.lastPathComponent
    }

    // MARK: - Terminal notice injection (US-007)

    /// Inject a single informational notice line into the iTerm2 window whose
    /// working directory is exactly `rootPath`. iTerm2 only — the session-id
    /// write path (`KeystrokeInjector.sendText`) never `activate`s iTerm, so it
    /// never steals focus. `pressReturn: false` — the line is a comment, never
    /// a prompt, and must NOT execute.
    private func injectNotice(rootPath: String, taskId: String, title: String) {
        guard let windowManager, let keystrokeInjector else { return }

        let target = Self.matchTerminal(
            windows: windowManager.windows,
            rootPath: rootPath,
            zOrderIds: WindowManager.fetchWindowList().map(\.id))

        guard let window = target else {
            SwrmEventTailer.globalLog(
                "inject: no tracked terminal at \(rootPath) for task=\(taskId) — skipping")
            return
        }
        // Terminal.app has no shell-var access (cwdPath stays nil, so it can't
        // match here) — but an iTerm window whose session id hasn't resolved
        // yet can. MVP is iTerm2-only: skip + log rather than fall back to a
        // focus-stealing front-window write.
        guard let sessionId = window.iterm2SessionId else {
            SwrmEventTailer.globalLog(
                "inject: matched \(window.id) at \(rootPath) but no iterm2 session id — skipping (Terminal.app / unresolved)")
            return
        }

        let notice = Self.noticeLine(title: title, taskId: taskId)
        Task {
            let result = await keystrokeInjector.sendText(
                notice, to: window.id, pressReturn: false, terminalApp: .iterm2,
                windowName: window.name, cgWindowNumber: window.windowNumber,
                iterm2SessionId: sessionId)
            if result.success {
                SwrmEventTailer.globalLog(
                    "inject: notice into \(window.id) at \(rootPath) for task=\(taskId)")
            } else {
                SwrmEventTailer.globalLog(
                    "inject: FAILED into \(window.id) at \(rootPath): \(result.error ?? "unknown")")
            }
        }
    }

    /// The notice text. Single line, leading `#` so a shell or REPL treats it
    /// as a comment if the user does later hit return.
    static func noticeLine(title: String, taskId: String) -> String {
        "# swrm: started \"\(title)\" (#\(taskId))"
    }

    /// Pure window matcher (testable): pick the tracked window whose cwd is
    /// exactly `rootPath`. If several match, prefer the most-recently-active —
    /// the one earliest in `zOrderIds` (CG front-to-back order). nil if none.
    static func matchTerminal(windows: [ManagedWindow], rootPath: String,
                              zOrderIds: [String]) -> ManagedWindow? {
        let root = canonicalPath(rootPath)
        let matches = windows.filter { w in
            guard let cwd = w.cwdPath, !cwd.isEmpty else { return false }
            return canonicalPath(cwd) == root
        }
        guard !matches.isEmpty else { return nil }
        if matches.count == 1 { return matches[0] }

        // Tiebreak by z-order: lower index == more frontmost == most recent.
        // Windows absent from zOrderIds (off-screen) sort last but stay stable.
        let rank = Dictionary(zOrderIds.enumerated().map { ($1, $0) },
                              uniquingKeysWith: { first, _ in first })
        return matches.min { a, b in
            (rank[a.id] ?? Int.max) < (rank[b.id] ?? Int.max)
        }
    }

    /// Normalize a path for exact comparison: resolve `~`, `.`/`..`, and strip
    /// a trailing slash so "/a/b" and "/a/b/" compare equal.
    private static func canonicalPath(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = (p as NSString).standardizingPath
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
