import Foundation

/// Q-21's second signal for "is this terminal waiting on a human?".
///
/// `TerminalStateDetector` decides that question from CPU alone
/// (`totalCPU < cpuThreshold`), and an agent blocked on an LLM stream or an MCP
/// call burns ~0% CPU. Measured 2026-08-19: 44 `neutral` ↔ `waiting_for_input`
/// transitions in 180s for a single window, every raise clearing again 1-5s
/// later — so none of them were prompts. Q-20's asymmetric debounce made the
/// quiet run longer, which cannot help, because the two states are equally
/// quiet.
///
/// Screen content settles it, but not by looking for a prompt: Claude Code
/// draws its `❯` input box while it is working too, so the box's presence
/// proves nothing. What differs is MOVEMENT. A working agent redraws a live
/// counter every frame (`✶ Crystallizing… (40s · ↓ 1.4k tokens)`); a finished
/// one is frozen (`✻ Cooked for 23m 34s`, byte-identical across reads a second
/// apart). Comparing two captures a few hundred milliseconds apart therefore
/// answers the question without knowing any agent's dialect — which matters,
/// because the status verbs are randomized per turn and every CLI draws its own
/// widgets.
enum PaneStability {

    /// CSI/OSC escape sequences. A terminal re-emits colour for reasons that
    /// have nothing to do with an agent running, so a repaint that changes only
    /// styling must not read as movement.
    private static let ansiPattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{7}]*(?:\u{7}|\u{1B}\\\\)"

    /// Normalized form of a capture, or nil when there is nothing to compare.
    ///
    /// Empty is nil rather than an empty string on purpose: `readContent`
    /// returns empty when the AppleScript failed or the window had no session,
    /// and two failures compared as equal would report "stable" for exactly the
    /// windows this gate cannot see.
    static func fingerprint(_ content: String) -> String? {
        let stripped = content.replacingOccurrences(
            of: ansiPattern, with: "", options: .regularExpression)
        let lines = stripped
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// True when two captures of the same pane show no movement — the caller's
    /// evidence that the window is idle rather than mid-turn.
    ///
    /// False when either capture is unusable. Callers must not read that as
    /// "busy": it means "no answer", and the caller decides what to do without
    /// one. `TerminalStateDetector` fails open there and logs, so a missing
    /// Automation grant degrades to the old CPU-only behaviour loudly instead
    /// of silently killing the badge.
    static func isStable(_ first: String, _ second: String) -> Bool {
        guard let a = fingerprint(first), let b = fingerprint(second) else { return false }
        return a == b
    }
}
