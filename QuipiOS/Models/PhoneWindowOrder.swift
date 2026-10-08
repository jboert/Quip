import Foundation

/// The order the phone's grid shows windows in: the user's persisted
/// drag-reorder sequence, with pinned windows floated to the front.
///
/// The drag order used to be the whole story, so a pin made on either peer
/// changed nothing on the phone: the Mac floated the window to the front of
/// its list, the phone re-sorted it straight back into its saved slot. Pins
/// now win, the same way they do on the Mac (`WindowPinOrder`), so a pinned
/// card is the first cell, top left, like a pinned browser tab (Q-58).
enum PhoneWindowOrder {

    /// PURE: known ids sort by saved position; ids not in `savedOrder` keep
    /// their incoming position after the known ones; then pinned windows move
    /// to the front, keeping their relative order.
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
