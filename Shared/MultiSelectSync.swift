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
    /// cursor DOWN to each toggled option in ascending order — one `"space"` per
    /// toggle — and finishes with a single `"return"`. When nothing differs the
    /// result is empty (nothing to submit, no accidental toggles).
    ///
    /// The only tokens emitted are `"down"`, `"space"`, and `"return"` — the
    /// vocabulary the Mac's `sendKeystroke` understands. The cursor defaults to
    /// option 1 when no marker is present; a toggle above the current cursor
    /// needs no downward move (clamped to zero) since there is no "up" token.
    static func keystrokes(desired: Set<Int>, liveContent: String) -> [String] {
        let current = NumberedPromptDetector.checkedOptions(in: liveContent)
        let toggles = togglesToReach(desired: desired, from: current)
        guard !toggles.isEmpty else { return [] }

        var cursor = NumberedPromptDetector.cursorOption(in: liveContent) ?? 1
        var out: [String] = []
        for option in toggles {
            let downs = max(0, option - cursor)
            out.append(contentsOf: Array(repeating: "down", count: downs))
            out.append("space")
            cursor = option
        }
        out.append("return")
        return out
    }
}
