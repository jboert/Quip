import Foundation

/// How much of a terminal's text the Mac sends to the phone. iTerm2's
/// `contents` includes the whole scrollback, so this cap is what decides how
/// far up the phone can scroll. It was 200 lines, about three screens, which
/// is why scrolling up on the phone ran out almost at once. 2,000 lines of
/// ~100 chars is ~200 KB, far below `WSLimits.maxMessageBytes`.
enum TerminalContentWindow {
    static let maxLines = 2000

    /// The last `maxLines` lines of `content`, newest kept.
    static func tail(_ content: String) -> String {
        content.components(separatedBy: "\n").suffix(maxLines).joined(separator: "\n")
    }
}
