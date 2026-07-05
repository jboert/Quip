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
}
