// WindowPinOrder.swift
// Shared — pinned windows float to the top of whatever order produced the list

import Foundation

/// Lifts pinned windows to the front of an already-ordered list.
///
/// Applied AFTER ordering rather than inside it, so it composes with every
/// order Quip has: screen order, a drag, a wand sort. Pinning answers "keep
/// this one where I can see it", which is a different question from "what
/// order are the rest in", and folding the two together would mean a re-sort
/// could quietly drop a pin.
///
/// Relative order is preserved inside both groups: pinned windows keep the
/// order they had, and so does everything else. A pin is not a placement.
enum WindowPinOrder {

    static func apply(_ ids: [String], pinned: Set<String>) -> [String] {
        guard !pinned.isEmpty else { return ids }
        var front: [String] = []
        var rest: [String] = []
        for id in ids {
            if pinned.contains(id) { front.append(id) } else { rest.append(id) }
        }
        return front + rest
    }

    /// Pins for windows that are not on screen right now are KEPT, not dropped.
    /// A terminal you closed for an hour should still be pinned when it comes
    /// back — but its id carries the CoreGraphics window number, so "comes
    /// back" means the same window, not a reopened one. Ids are only forgotten
    /// when the user unpins them, or by `forget(_:keeping:)` when the caller
    /// has a reason to prune.
    static func forget(_ pinned: Set<String>, keeping liveIDs: Set<String>) -> Set<String> {
        pinned.intersection(liveIDs)
    }
}
