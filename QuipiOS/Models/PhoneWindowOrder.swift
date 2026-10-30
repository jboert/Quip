import Foundation

enum PhoneWindowOrder {

    /// Q-88 US-004: how the window grid is ordered. Stored as
    /// `windowOrderMode`; empty means not chosen yet (see `initialMode`).
    enum Mode: String, CaseIterable {
        /// The windows used last come first (the recency stack).
        case recent
        /// The order the user dragged the cards into (`phoneWindowOrderJSON`).
        case manual

        static let storageKey = "windowOrderMode"
    }

    /// The mode for a phone that has never chosen one. `phoneWindowOrderJSON`
    /// is filled for everyone (each layout appends new ids), so "non-empty"
    /// does not mean "dragged". A drag is what makes the saved order differ
    /// from the Mac's: then keep Manual, else start in Recent.
    static func initialMode(savedOrder: [String], macOrder: [String]) -> Mode {
        let live = Set(macOrder)
        let saved = savedOrder.filter { live.contains($0) }
        let known = Set(saved)
        return saved == macOrder.filter { known.contains($0) } ? .recent : .manual
    }

    /// `windows` in the grid's order for `mode`. Recent sorts by position in
    /// `recency` (most recent first); Manual by `savedOrder`. Ids in neither
    /// list keep the Mac's order after the known ones. Pins come first in
    /// both modes (Q-58).
    static func display(_ windows: [WindowState], mode: Mode,
                        savedOrder: [String], recency: [String]) -> [WindowState] {
        display(windows, savedOrder: mode == .recent ? recency : savedOrder)
    }

    static func display(_ windows: [WindowState], savedOrder: [String]) -> [WindowState] {
        let ordered: [WindowState]
        if savedOrder.isEmpty {
            ordered = windows
        } else {
            let rank = Dictionary(
                savedOrder.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
            ordered = windows.enumerated().sorted { a, b in
                let ra = rank[a.element.id] ?? Int.max
                let rb = rank[b.element.id] ?? Int.max
                if ra != rb { return ra < rb }
                return a.offset < b.offset
            }.map(\.element)
        }
        let pinned = Set(ordered.filter(\.isPinned).map(\.id))
        guard !pinned.isEmpty else { return ordered }
        let ids = WindowPinOrder.apply(ordered.map(\.id), pinned: pinned)
        var byID: [String: WindowState] = [:]
        for window in ordered { byID[window.id] = window }
        return ids.compactMap { byID[$0] }
    }
}
