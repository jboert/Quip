import Foundation

enum TerminalContentWindow {
    static let maxLines = 2000

    static func tail(_ content: String) -> String {
        content.components(separatedBy: "\n").suffix(maxLines).joined(separator: "\n")
    }

    /// Shape a terminal buffer for the phone's text view: drop Claude Code's
    /// "✔ Update installed · Restart to update" notice from the footer, and
    /// collapse blank-line runs (the TUI pads above its footer, which left a
    /// screenful of gap under the last real message on the phone).
    static func tidy(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        let footerStart = max(0, lines.count - 12)
        lines = lines.enumerated().compactMap { i, line in
            i >= footerStart && (line.contains("Update installed") || line.contains("Restart to update"))
                ? nil : line
        }
        var out: [String] = []
        for line in lines {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, let prev = out.last, prev.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
