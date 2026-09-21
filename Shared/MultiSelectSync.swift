import Foundation

/// Pure helpers for driving an interactive checkbox multi-select widget from a
/// desired FINAL selection instead of a blind set of toggles.
///
/// The phone sends an ABSOLUTE desired selection; the Mac must translate that
/// into the minimal number of space-toggle keystrokes given whatever the widget
/// has already PRE-CHECKED. These helpers are Foundation-only so they compile in
/// the swiftc assertion harness (tools/run-multiselect-tests.sh) with no Xcode.
enum MultiSelectSync {
    /// Option numbers that must be space-toggled to move the widget from its
    /// `current` checked set to the `desired` final set.
    ///
    /// This is the symmetric difference of the two sets — every option that is
    /// desired-but-off (turn ON) plus every option that is on-but-undesired
    /// (turn OFF) — returned ascending so the cursor only ever walks downward.
    static func togglesToReach(desired: Set<Int>, from current: Set<Int>) -> [Int] {
        desired.symmetricDifference(current).sorted()
    }

    /// The options an interactive checkbox widget starts with PRE-CHECKED, read
    /// straight from live terminal content. The iOS answer bar seeds its picks
    /// from this so its Submit represents the desired FINAL set (consumed by the
    /// Mac `keystrokes` diff), not a blind toggle-from-empty. Empty for content
    /// with no checked boxes or no multi-select prompt.
    static func initialPicks(liveContent: String) -> Set<Int> {
        NumberedPromptDetector.checkedOptions(in: liveContent)
    }

    /// Turn a desired FINAL selection plus the live terminal content into the
    /// exact keystroke sequence the Mac injector should replay.
    ///
    /// Reads the live checked set and starting cursor straight from the Shared
    /// `NumberedPromptDetector`, computes the minimal toggle diff, then walks the
    /// cursor to each toggled option in ascending order — moving `"down"` OR
    /// `"up"` as needed since the live cursor can start on any option (Claude
    /// renders the highlight wherever it last sat, not always the top) — presses
    /// one `"space"` per toggle, and finishes with a single `"return"`.
    ///
    /// When nothing needs toggling (the desired set already matches what's
    /// pre-checked) the result is still a bare commit — `["return"]`, or the
    /// walk onto the Submit row plus `"return"`: a Submit must always CONFIRM
    /// the widget, otherwise tapping Submit to accept the pre-checked defaults
    /// would inject nothing and leave the prompt open.
    ///
    /// The only tokens emitted are `"up"`, `"down"`, `"space"`, and `"return"` —
    /// all in the vocabulary the Mac's `sendKeystroke` understands. The cursor
    /// defaults to option 1 when no marker is present.
    static func keystrokes(desired: Set<Int>, liveContent: String) -> [String] {
        let current = NumberedPromptDetector.checkedOptions(in: liveContent)
        let toggles = togglesToReach(desired: desired, from: current)
        var cursor = NumberedPromptDetector.cursorOption(in: liveContent) ?? 1
        var out: [String] = []
        for option in toggles {
            let delta = option - cursor
            out.append(contentsOf: Array(repeating: delta >= 0 ? "down" : "up", count: abs(delta)))
            out.append("space")
            cursor = option
        }
        // Commit. Two widget dialects, told apart by whether the live screen
        // renders a navigable Submit row under the options:
        //
        //  • Submit row present (Claude Code's AskUserQuestion multi-select) —
        //    Return on an OPTION row toggles that option's checkbox instead of
        //    submitting (verified against a live widget: the last pick came back
        //    OFF and the prompt stayed open, which is exactly the "it only
        //    selects one" report). Walk one row past the last option onto Submit
        //    and press Return there.
        //  • No Submit row — the plain dialect: Return confirms in place.
        if NumberedPromptDetector.hasSubmitRow(in: liveContent),
           let last = NumberedPromptDetector.lastOption(in: liveContent) {
            let delta = (last + 1) - cursor
            out.append(contentsOf: Array(repeating: delta >= 0 ? "down" : "up", count: abs(delta)))
        }
        out.append("return")
        return out
    }
}
