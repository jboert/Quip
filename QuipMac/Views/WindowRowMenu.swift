// WindowRowMenu.swift
// QuipMac — Titles for the sidebar row's context menu

/// The sidebar row's pin and move controls are hover glyphs — invisible to
/// anyone not holding a pointer over the row. The context menu is the path
/// that does not need a pointer, so it must offer every one of them; this is
/// the single list of what it offers, in order.
enum WindowRowMenu {
    static let pin = "Pin to top"
    static let unpin = "Unpin from top"
    static let moveUp = "Move Up"
    static let moveDown = "Move Down"

    /// A move title appears only when that move is possible — a row at the edge
    /// of its tier has no neighbour to swap with, and a menu item that does
    /// nothing reads as broken.
    static func actions(isPinned: Bool, canMoveUp: Bool, canMoveDown: Bool) -> [String] {
        var titles = [isPinned ? unpin : pin]
        if canMoveUp { titles.append(moveUp) }
        if canMoveDown { titles.append(moveDown) }
        return titles
    }
}
