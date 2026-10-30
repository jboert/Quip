import Foundation

enum PhoneWindowOrder {

    /// Q-88 US-004: how the window grid is ordered. The user's choice is
    /// stored as `windowOrderMode` (backed up); empty means not chosen yet.
    /// Until then the first layout's guess (`initialMode`) is stored on the
    /// phone only, as `windowOrderModeGuess`.
    enum Mode: String, CaseIterable {
        /// The windows used last come first (the recency stack).
        case recent
        /// The order the user dragged the cards into (`phoneWindowOrderJSON`).
        case manual

        static let storageKey = "windowOrderMode"
        /// Device-local, never in `PreferencesSnapshot`: a guess is not an
        /// edit, so it must not move the backup stamp or override a restore.
        static let guessKey = "windowOrderModeGuess"

        /// The mode in force: the user's choice, else the guess, else Manual
        /// (the order the grid always showed before a guess is made).
        static func resolve(chosen: String, guess: String) -> Mode {
            Mode(rawValue: chosen) ?? Mode(rawValue: guess) ?? .manual
        }
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
