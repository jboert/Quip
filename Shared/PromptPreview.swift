import Foundation

/// The one line a push shows for a waiting prompt: the question, not the
/// option rows, borders or key hints around it (board Q-56). Pure.
enum PromptPreview {
    /// The last question-like line before the first option row, or the last
    /// question-like line of the pane when there are no options. nil when
    /// nothing readable is there. Truncated to `maxLength` with an ellipsis.
    static func line(in content: String, maxLength: Int = 90) -> String? {
        let raw = Array(content.components(separatedBy: .newlines).suffix(40))
        let cleaned = raw.map(clean)
        let firstOption = cleaned.firstIndex(where: isOptionRow)
        let candidates = firstOption.map { Array(cleaned[..<$0]) } ?? cleaned
        guard let question = candidates.last(where: { !$0.isEmpty && !isOptionRow($0) && !isChrome($0) }) else {
            return nil
        }
        guard question.count > maxLength else { return question }
        return String(question.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")
    private static let optionRow = try! NSRegularExpression(
        pattern: #"^\s*(?:[❯>•]\s*)?(?:\d+[.)]|\[[ xX✔✓]?\]|\([ xX✔✓]?\))\s"#)

    /// ANSI stripped, box-drawing and selection markers removed, trimmed.
    static func clean(_ line: String) -> String {
        let noAnsi = ansi.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        let kept = noAnsi.unicodeScalars.filter { scalar in
            !(0x2500...0x257F).contains(scalar.value)   // box drawing
                && !(0x2580...0x259F).contains(scalar.value) // block elements
        }
        var text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        while let first = text.first, "❯>•│┃".contains(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    static func isOptionRow(_ line: String) -> Bool {
        optionRow.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Key hints and status lines the CLIs draw under a prompt.
    static func isChrome(_ line: String) -> Bool {
        let lower = line.lowercased()
        let hints = ["enter to select", "esc to cancel", "press enter", "to navigate", "tab to", "↑/↓", "? for shortcuts",
                     "ctrl+c", "esc to interrupt", "enter to confirm", "space to select"]
        if hints.contains(where: { lower.contains($0) }) { return true }
        // A bare prompt character or cursor box with nothing typed.
        return line.allSatisfy { "❯>$%#_ ".contains($0) }
    }
}
