import CoreGraphics

/// Whether a terminal text view should follow new output. It follows only
/// while the reader is at (or within `slack` of) the bottom, the same rule
/// the screenshot view uses. Before, every refresh scrolled to the bottom,
/// so scrolling up to read history was undone by the next update.
enum TerminalScrollPolicy {
    static let slack: CGFloat = 40

    static func isPinnedToBottom(contentHeight: CGFloat, offsetY: CGFloat, visibleHeight: CGFloat) -> Bool {
        contentHeight - (offsetY + visibleHeight) < slack
    }
}
