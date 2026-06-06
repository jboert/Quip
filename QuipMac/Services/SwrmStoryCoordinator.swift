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

    init(webSocketServer: WebSocketServer? = nil) {
        self.webSocketServer = webSocketServer
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
    }

    /// Prefer the event's own `project` label; fall back to the root folder
    /// name so the card always shows something human-readable.
    private func projectName(for tailer: SwrmEventTailer, event: SwrmEvent) -> String {
        if let p = event.project, !p.isEmpty { return p }
        return tailer.projectRoot.lastPathComponent
    }
}
