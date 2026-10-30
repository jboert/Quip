import Foundation

/// Q-89: answers Yes or No to a menu driven by the arrow keys, numbered or not.
///
/// Agent CLIs ask some questions as a cursor menu with no numbers —
///
///     Start a cloud session?
///     ❯ Yes
///       No
///
/// — so a typed `y` does nothing and `NumberedPromptDetector` finds no options
/// to make buttons from. This finds the menu by its cursor row and the rows
/// aligned with it, picks the row that means Yes (or No), and says which
/// arrow keys reach it. Both peers use it: the phone to decide whether to show
/// Yes/No, the Mac to decide what to press (two-peer contract — ship detection
/// changes to both).
enum ArrowMenu {
    struct Menu: Equatable {
        /// Row labels top to bottom, with any `1.` numbering removed.
        let labels: [String]
        /// Index of the highlighted row.
        let cursor: Int
    }

    enum Answer { case yes, no }

    enum Plan: Equatable {
        /// Press these (`up` / `down`, then `return`).
        case keys([String])
        /// No Yes/No menu on screen: type `y` / `n` as before.
        case typeLetter
        /// A Yes/No menu is on screen but has no row for this answer.
        /// Send nothing.
        case noMatchingRow
    }

    static let cursorMarkers: Set<Character> = ["❯", "›", ">", "▶", "▸", "→", "➤"]

    /// Words a Yes or No row starts with. An exact "yes" / "no" wins over these.
    static let yesWords: Set<String> = ["allow", "approve", "accept", "confirm", "continue", "proceed", "trust", "ok", "okay"]
    static let noWords: Set<String> = ["deny", "reject", "decline", "cancel", "back", "skip", "exit", "quit", "dont", "don't"]

    /// A row that grants more than this one answer ("Yes, and don't ask
    /// again", "Allow always") loses to a one-time row that means the same.
    static let persistentMarkers = ["always", "don't ask", "dont ask", "do not ask", "this session", "remember", "forever"]

    /// Only the screen's last lines can hold a live menu.
    static let tailLines = 30

    static func detect(in content: String) -> Menu? {
        let lines = content.components(separatedBy: "\n").suffix(tailLines).map(stripBorders)
        // Only the bottom-most cursor row counts. An answered menu still in
        // the scrollback above a live composer must never be found: arrows
        // and Return would land in the composer.
        guard let index = lines.lastIndex(where: { line in
                  line.first(where: { $0 != " " }).map(cursorMarkers.contains) ?? false
              }),
              let column = labelColumn(ofCursorLine: lines[index]) else { return nil }
        var top = index
        while top - 1 >= lines.startIndex, label(of: lines[top - 1], at: column) != nil { top -= 1 }
        var bottom = index
        while bottom + 1 < lines.endIndex, label(of: lines[bottom + 1], at: column) != nil { bottom += 1 }
        guard bottom > top else { return nil }
        let labels = (top...bottom).map { i -> String in
            let raw = i == index ? String(Array(lines[i])[column...]) : label(of: lines[i], at: column)!
            return stripNumbering(raw)
        }
        return Menu(labels: labels, cursor: index - top)
    }

    /// The row meaning `answer`: an exact "yes"/"no" first, then a synonym;
    /// within either, a one-time row before a persistent one.
    static func row(for answer: Answer, in menu: Menu) -> Int? {
        let exact = answer == .yes ? "yes" : "no"
        let words = answer == .yes ? yesWords : noWords
        let firsts = menu.labels.map(firstWord)
        func pick(_ rows: [Int]) -> Int? {
            rows.first { i in !persistentMarkers.contains { menu.labels[i].lowercased().contains($0) } } ?? rows.first
        }
        if let i = pick(firsts.indices.filter { firsts[$0] == exact }) { return i }
        if answer == .no, let i = menu.labels.firstIndex(where: { $0.lowercased().hasPrefix("do not") }) { return i }
        return pick(firsts.indices.filter { words.contains(firsts[$0]) })
    }

    /// True when a menu with a Yes or a No row is on screen.
    static func isYesNoMenu(in content: String) -> Bool {
        guard let menu = detect(in: content) else { return false }
        return row(for: .yes, in: menu) != nil || row(for: .no, in: menu) != nil
    }

    /// `agentCLI` false (a shell, or not known to be an agent) always types
    /// the letter: under a shell prompt, ↑ + Return would re-run the last
    /// history command.
    static func plan(_ answer: Answer, content: String, agentCLI: Bool) -> Plan {
        guard agentCLI, let menu = detect(in: content),
              row(for: .yes, in: menu) != nil || row(for: .no, in: menu) != nil else { return .typeLetter }
        guard let target = row(for: answer, in: menu) else { return .noMatchingRow }
        let step = target - menu.cursor
        return .keys(Array(repeating: step > 0 ? "down" : "up", count: abs(step)) + ["return"])
    }

    // MARK: Parsing

    /// Box-drawing frames around a dialog (`│ ❯ Yes │`) are not part of a row.
    private static func stripBorders(_ line: String) -> String {
        var s = line
        while let last = s.last, last == " " || last == "│" || last == "┃" { s.removeLast() }
        if let first = s.first(where: { $0 != " " }), first == "│" || first == "┃",
           let i = s.firstIndex(of: first) {
            s.replaceSubrange(i...i, with: " ")
        }
        return s
    }

    /// Where the label starts on a cursor row (`  ❯ Yes` → 4), or nil.
    private static func labelColumn(ofCursorLine line: String) -> Int? {
        let chars = Array(line)
        guard let markerIndex = chars.firstIndex(where: { $0 != " " }),
              cursorMarkers.contains(chars[markerIndex]) else { return nil }
        var column = markerIndex + 1
        while column < chars.count, chars[column] == " " { column += 1 }
        guard column > markerIndex + 1, column < chars.count, isLabelStart(chars[column]) else { return nil }
        return column
    }

    /// A sibling row: blank up to `column`, a label starting exactly there.
    private static func label(of line: String, at column: Int) -> String? {
        let chars = Array(line)
        guard chars.count > column, chars[..<column].allSatisfy({ $0 == " " }),
              isLabelStart(chars[column]) else { return nil }
        return String(chars[column...])
    }

    private static func isLabelStart(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func stripNumbering(_ label: String) -> String {
        guard let match = label.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) else { return label }
        return String(label[match.upperBound...])
    }

    private static func firstWord(_ label: String) -> String {
        String(label.lowercased().prefix { $0.isLetter || $0 == "'" })
    }
}
