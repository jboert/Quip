import CoreGraphics
import CryptoKit
import Foundation

/// Whether a terminal text view should follow new output. It follows only
/// while the reader is at (or within `slack` of) the bottom, the same rule
/// the screenshot view uses. Before, every refresh scrolled to the bottom,
/// so scrolling up to read history was undone by the next update.
enum TerminalScrollPolicy {
    static let slack: CGFloat = 40

    static func isPinnedToBottom(contentHeight: CGFloat, offsetY: CGFloat, visibleHeight: CGFloat) -> Bool {
        contentHeight - (offsetY + visibleHeight) < slack
    }

    // MARK: Q-88 US-008 — scroll position across launches and window switches

    /// The anchor for `lines[index]` being the first visible line.
    static func anchor(lines: [String], firstVisible index: Int) -> ScrollAnchor? {
        guard lines.indices.contains(index) else { return nil }
        return ScrollAnchor(lineHash: hash(lines[index]), fromEnd: lines.count - 1 - index)
    }

    /// Where `anchor`'s line is now: the exact match nearest the saved
    /// distance from the end, searching outward (new output pushes the line
    /// further from the end; a tie goes to the earlier line, the way output
    /// moves it). Nil when the line is gone: open at the bottom and follow.
    static func resolve(anchor: ScrollAnchor, lines: [String]) -> Int? {
        let target = min(max(0, lines.count - 1 - anchor.fromEnd), lines.count - 1)
        for distance in 0..<lines.count {
            for index in [target - distance, target + distance] where lines.indices.contains(index) {
                if hash(lines[index]) == anchor.lineHash { return index }
            }
        }
        return nil
    }

    static func hash(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
