// WindowScreenOrder.swift
// Shared — list the windows in the order they sit on the screen

import Foundation

/// Puts a window list in reading order: terminals first, then by display, then
/// top row before bottom row, then left to right.
///
/// CoreGraphics hands back windows in front-to-back order, which is the order
/// they were last focused in — it has nothing to do with where they are, so the
/// list and the desk disagree the moment you click something. This is the rule
/// that makes the sidebar match what the user is looking at.
///
/// Rows, not raw Y: two side-by-side terminals are never pixel-aligned, and
/// sorting on Y alone would interleave the columns of a tiled desk. Windows
/// whose tops are within half the first window's height belong to the same row
/// and are ordered left to right.
///
/// Doubles rather than `CGRect` so the type stays Foundation-only and testable
/// in the swiftc harness.
enum WindowScreenOrder {

    struct Item: Sendable, Equatable {
        let id: String
        /// Grouping rank — terminals 0, other targets 1, everything else 2.
        /// Applied before position, so "focus on terminals first" survives any
        /// arrangement of the desk.
        let tier: Int
        /// Origin of the display this window sits on, so windows are grouped by
        /// monitor before they are ordered within one.
        let displayX: Double
        let displayY: Double
        let x: Double
        let y: Double
        let height: Double

        init(id: String, tier: Int, displayX: Double, displayY: Double,
             x: Double, y: Double, height: Double) {
            self.id = id
            self.tier = tier
            self.displayX = displayX
            self.displayY = displayY
            self.x = x
            self.y = y
            self.height = height
        }
    }

    static func order(_ items: [Item]) -> [String] {
        // Stable grouping: tier first, then the display's own position (left
        // monitor before right, upper before lower).
        let groups = Dictionary(grouping: items) {
            GroupKey(tier: $0.tier, displayX: $0.displayX, displayY: $0.displayY)
        }
        return groups.keys.sorted().flatMap { key in
            readingOrder(groups[key] ?? [])
        }
    }

    /// One tier on one display: banded into rows top-down, each row left to
    /// right.
    private static func readingOrder(_ items: [Item]) -> [String] {
        // Ties broken by id so the order is total — two windows at the same
        // spot (a sheet over its parent, a just-opened window that has not been
        // placed yet) must not swap places between snapshots and make the list
        // look like it is churning again.
        let byTop = items.sorted {
            $0.y != $1.y ? $0.y < $1.y : ($0.x != $1.x ? $0.x < $1.x : $0.id < $1.id)
        }

        var result: [String] = []
        var row: [Item] = []
        var rowTop: Double = 0
        var rowTolerance: Double = 0

        func flushRow() {
            guard !row.isEmpty else { return }
            result += row
                .sorted { $0.x != $1.x ? $0.x < $1.x : $0.id < $1.id }
                .map(\.id)
            row.removeAll()
        }

        for item in byTop {
            if row.isEmpty {
                rowTop = item.y
                // Half the first window's height: a full-height terminal next
                // to a half-height one still reads as the same row, while a
                // window genuinely stacked below it does not.
                rowTolerance = max(item.height / 2, 1)
            } else if item.y - rowTop > rowTolerance {
                flushRow()
                rowTop = item.y
                rowTolerance = max(item.height / 2, 1)
            }
            row.append(item)
        }
        flushRow()
        return result
    }

    private struct GroupKey: Hashable, Comparable {
        let tier: Int
        let displayX: Double
        let displayY: Double

        static func < (a: GroupKey, b: GroupKey) -> Bool {
            if a.tier != b.tier { return a.tier < b.tier }
            if a.displayX != b.displayX { return a.displayX < b.displayX }
            return a.displayY < b.displayY
        }
    }
}
