// ClaudeModeDetector.swift
// QuipMac — Scrapes Claude Code's current mode (normal / plan / autoAccept) from
// the terminal buffer of each enabled window. Foundation for shortcut features
// like real plan-mode cycling (#6) and context-aware prompt-response buttons (#18).
//
// Design:
//   - Reading the terminal buffer costs ~50-200ms per window (AppleScript hop to
//     iTerm2), so the poll cadence here is deliberately slower (2s) than
//     TerminalStateDetector's 0.25s. Mode changes are rare — caused only by the
//     user pressing Shift+Tab — and a 2s detection latency is invisible in practice.
//   - All buffer reads happen on a background queue; the main-actor state is only
//     touched for publishing results.
//   - Only the LAST ~40 lines of the buffer are scanned: Claude Code renders its
//     mode indicator in the status/footer region, and scanning prose anywhere
//     earlier would false-positive on transcripts that mention "plan mode on"
//     in a code block or chat history.

import CoreGraphics
import Foundation
import Observation

enum ClaudeModeScanner {
    /// Scan terminal buffer text for Claude Code's current mode indicator.
    /// Returns `nil` if no indicator was found (treat as "unknown" / "not a Claude session").
    /// Only the tail of the buffer is inspected — see `tailLineCount` rationale above.
    ///
    /// Cycle order (Shift+Tab): normal → autoAccept → plan → normal. In normal mode
    /// neither "plan mode on" nor "auto-accept edits on" is visible, so returning .normal
    /// requires a positive signal that Claude Code is present AND neither string is in the
    /// tail. We conservatively return nil when neither indicator is found — callers can
    /// decide to treat nil as "normal mode" if they also have confirmation (e.g. isThinking)
    /// that Claude is running in that window.
    static func detect(in bufferText: String, tailLineCount: Int = 40) -> ClaudeMode? {
        // Take the last N lines — everything above is old prose that could
        // false-positive on literal mentions of "plan mode on".
        let lines = bufferText.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(tailLineCount).joined(separator: "\n").lowercased()

        // Check plan mode first — if both strings appeared (shouldn't happen),
        // plan is the more specific state and wins.
        if tail.contains("plan mode on") {
            return .plan
        }
        if tail.contains("auto-accept edits on") {
            return .autoAccept
        }
        return nil
    }
}

@MainActor
@Observable
final class ClaudeModeDetector {

    /// Maps window IDs to their last-detected Claude mode. Windows not in the
    /// dict (or mapped to nil) either haven't been scanned yet or aren't running
    /// Claude Code at all.
    var windowModes: [String: ClaudeMode] = [:]

    /// Fires with (windowId, oldMode, newMode) whenever a window's mode changes
    /// (including first-detection transitions from nil → a value).
    var onModeChange: ((String, ClaudeMode?, ClaudeMode?) -> Void)?

    /// Cadence at which each tracked window's terminal buffer is scanned.
    /// 2s is a deliberate compromise between latency and AppleScript cost —
    /// faster polling would starve the MainActor when many windows are open.
    var pollingInterval: TimeInterval = 2.0

    private var pollTimer: Timer?
    private let pollQueue = DispatchQueue(label: "quip.claude-mode-poll", qos: .utility)

    /// Set of (windowId, terminalApp, windowNumber, iterm2SessionId) tuples to poll.
    /// Populated by the app (QuipMacApp.swift) via setTrackedWindows() each poll cycle.
    private var tracked: [TrackedWindow] = []

    struct TrackedWindow: Sendable {
        let windowId: String
        let terminalApp: TerminalApp
        let windowNumber: CGWindowID
        let iterm2SessionId: String?
    }

    /// Called by the app to refresh the set of windows to scan. Passing enabled
    /// windows only keeps the poll cost bounded to the windows the user actually cares about.
    func setTrackedWindows(_ windows: [TrackedWindow]) {
        tracked = windows
    }

    func startMonitoring(keystrokeInjector: KeystrokeInjector) {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.pollOnce(keystrokeInjector: keystrokeInjector)
        }
        print("[ClaudeModeDetector] Started monitoring (interval: \(pollingInterval)s)")
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        print("[ClaudeModeDetector] Stopped monitoring")
    }

    private func pollOnce(keystrokeInjector: KeystrokeInjector) {
        let snapshot = tracked
        pollQueue.async { [weak self] in
            guard let self else { return }
            var results: [(String, ClaudeMode?)] = []
            for tw in snapshot {
                let content = keystrokeInjector.readContent(
                    terminalApp: tw.terminalApp,
                    cgWindowNumber: tw.windowNumber,
                    iterm2SessionId: tw.iterm2SessionId
                ) ?? ""
                let mode = ClaudeModeScanner.detect(in: content)
                results.append((tw.windowId, mode))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (windowId, newMode) in results {
                    let oldMode = self.windowModes[windowId]
                    if oldMode != newMode {
                        self.windowModes[windowId] = newMode
                        self.onModeChange?(windowId, oldMode, newMode)
                    }
                }
            }
        }
    }
}
