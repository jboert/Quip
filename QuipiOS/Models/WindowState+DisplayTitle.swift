import Foundation

extension WindowState {
    /// What the phone calls this window everywhere it is named in one line:
    /// the folder when the Mac knows one, else the window's name. The card's
    /// primary label, the Broadcast sheet, its result line and the minimized
    /// tray all read this, so they cannot disagree.
    var displayTitle: String {
        guard let folder, !folder.isEmpty else { return name }
        return folder
    }
}
