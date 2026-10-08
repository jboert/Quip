import Foundation

/// The phone's dock-like tray of minimized windows (GH #39, board Q-53).
/// Pure: which windows the tray lists and what each pill says.
enum MinimizedTray {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        /// The folder when the Mac knows one, else the window's name, as the
        /// card's primary label does.
        let title: String
        /// The window's palette color, so the pill matches its card.
        let color: String
    }

    /// One entry per window the Mac reports minimized, in the Mac's order,
    /// so the tray and the grid agree.
    static func entries(_ windows: [WindowState]) -> [Entry] {
        windows.filter(\.isMinimized).map { window in
            Entry(id: window.id, title: window.displayTitle, color: window.color)
        }
    }
}
