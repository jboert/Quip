import Foundation

/// Q-21. The decision the detector makes after `TerminalStateDebounce` has
/// approved a raise into `waitingForInput` and a second pane capture has come
/// back from the background queue.
///
/// It exists as a separate pure type for the same reason `TerminalStateDebounce`
/// does: the alternative is logic that can only be exercised by spawning
/// `osascript` against a live terminal, which is exactly the shape of test that
/// did not catch the original flap.
enum PromptRaiseGate {

    /// What the second capture said about the pane.
    enum Stability {
        /// Two captures a few hundred ms apart were identical — nothing is
        /// redrawing, so the window really is sitting there.
        case stable
        /// The pane changed between captures. An agent mid-turn redraws a live
        /// counter every frame, so this is the Q-21 false positive being caught.
        case moving
        /// The pane could not be read at all: no Automation grant, a terminal
        /// that will not answer AppleScript, an empty capture.
        case unreadable
    }

    enum Outcome {
        case raise
        case drop
    }

    /// - Parameters:
    ///   - stability: what the re-read found.
    ///   - capturedAt: the poll generation in force when the read was
    ///     dispatched.
    ///   - current: the generation now.
    ///
    /// Staleness is checked before anything else. A confirmation that outlived
    /// its generation describes a window that has since been untracked,
    /// retracked or switched to STT (Q-16b), so it cannot speak for the window
    /// that exists now — including when it is `unreadable`, where the
    /// fail-open rule would otherwise resurrect a raise for a dead window.
    ///
    /// `unreadable` fails OPEN: it raises, reproducing the pre-Q-21 CPU-only
    /// behaviour. Failing closed would silently stop badging real prompts
    /// wherever the grant is missing, and a dead badge that looks like a fixed
    /// flap is the worse outcome — the caller logs every skipped gate so the
    /// degradation is visible rather than inferred.
    static func decide(stability: Stability, capturedAt: Int, current: Int) -> Outcome {
        guard capturedAt == current else { return .drop }
        switch stability {
        case .stable, .unreadable: return .raise
        case .moving: return .drop
        }
    }
}
