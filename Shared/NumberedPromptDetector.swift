import Foundation

/// Detects Claude Code's numbered-prompt block in a terminal content
/// snapshot — the `❯ 1. Yes / 2. No / 3. Cancel` style affordance Claude
/// renders when asking the user to pick from a list. (§18.)
///
/// Disambiguation matters: a regular paragraph that happens to contain
/// "1." and "2." (e.g. a markdown ordered list in chat output) must NOT
/// trigger the auto-buttons, only Claude's structured prompt does.
///
/// Heuristic:
///   1. Scan from the END of the content (the most recent rendered
///      output) backward up to a small window — Claude's prompt sits at
///      the bottom of the visible viewport.
///   2. Find lines matching the prompt pattern: optional leading
///      whitespace + `❯ ` cursor marker OR start-of-line, then a digit,
///      a `.` or `)` separator, a space, then text.
///   3. Require AT LEAST ONE `❯`-prefixed line in the matched cluster
///      (Claude always renders the prompt with the cursor marker on the
///      currently-highlighted option). Without the marker, treat as
///      prose.
///   4. Return the contiguous option numbers (typically `[1, 2, 3]` or
///      `[1, 2]`), or nil if no valid prompt block is found.
///
/// The scan window is bounded so a `tail -f` log of numbered events
/// can't accidentally match. Pure function — testable without UI.
enum NumberedPromptDetector {

    /// Maximum number of trailing lines to inspect. Claude's prompt
    /// blocks typically fit in 5-10 lines including a header line.
    /// Anything past this is older output that shouldn't be considered
    /// part of the current prompt.
    static let scanLineLimit = 30

    /// Detect a numbered prompt block. Returns the contiguous option
    /// numbers (1-based, ascending) or nil when no prompt detected.
    static func detect(in content: String) -> [Int]? {
        bestRun(in: content)?.map(\.number)
    }

    private struct Match { let number: Int; let hasMarker: Bool; let normalized: String }

    /// Find the longest contiguous run of numbered-option lines that contains
    /// at least one `❯`/`>` marker (Claude's prompt block). Shared by `detect`
    /// (→ numbers) and `fingerprint` (→ normalized option text) so the two can
    /// never disagree about what the current prompt is.
    private static func bestRun(in content: String) -> [Match]? {
        guard !content.isEmpty else { return nil }

        // Take the last `scanLineLimit` lines so we don't false-positive
        // on prose far up the buffer.
        let allLines = content.components(separatedBy: "\n")
        let tail = Array(allLines.suffix(scanLineLimit))

        // Walk forward, collect runs of numbered-option lines; track
        // whether the run includes a `❯` marker line. Claude always
        // renders the cursor marker on the currently-selected option,
        // so a marker presence inside the block proves it's a real
        // prompt vs prose.
        var current: [Match] = []
        var best: [Match] = []
        func flush() {
            if current.contains(where: \.hasMarker), current.count > best.count {
                best = current
            }
        }
        for line in tail {
            if let (n, marker) = parseNumberedLine(line) {
                let m = Match(number: n, hasMarker: marker, normalized: normalizedOptionLine(line))
                if let last = current.last, n == last.number + 1 {
                    current.append(m)
                } else if n == 1 {
                    // Start of a new candidate block.
                    current = [m]
                } else {
                    // Out-of-order numbering — discard.
                    current = []
                }
            } else if !current.isEmpty {
                // Non-matching line breaks the run; remember it if it
                // beats the previous best, then reset.
                flush()
                current = []
            }
        }
        flush()  // trailing run

        return best.isEmpty ? nil : best
    }

    /// Normalize one option line to its stable identity: ANSI-stripped,
    /// trimmed, leading `❯`/`>` marker removed, internal whitespace collapsed.
    /// Dropping the marker is what makes the fingerprint stable as the
    /// highlight moves between options.
    private static func normalizedOptionLine(_ line: String) -> String {
        var s = stripANSI(line).trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("❯ ") { s.removeFirst(2) }
        else if s.hasPrefix("> ") { s.removeFirst(2) }
        return s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// Stable identity of the *set of options* currently on screen, used by
    /// the Mac to re-validate that a phone's one-tap answer still matches the
    /// live prompt before injecting (§3.2). Hashes the normalized option lines
    /// (ANSI-stripped, marker-dropped, whitespace-collapsed) so the value is
    /// stable as the `❯` highlight moves between options, but changes when the
    /// option text or count changes. Returns nil when no numbered prompt is
    /// present. FNV-1a → identical across platforms, no dependencies.
    static func fingerprint(in content: String) -> String? {
        guard let run = bestRun(in: content) else { return nil }
        return fnv1a(run.map(\.normalized).joined(separator: "\n"))
    }

    /// Detect a free-form yes/no prompt (e.g. "Continue? (y/n)") as opposed to
    /// a numbered list. Guards `press_y`/`press_n` re-validation. (§3.2)
    static func detectYesNo(in content: String) -> Bool {
        guard !content.isEmpty else { return false }
        for line in content.components(separatedBy: "\n").suffix(scanLineLimit) {
            let s = stripANSI(line).lowercased()
            if s.contains("(y/n)") || s.contains("(yes/no)") { return true }
        }
        return false
    }

    /// FNV-1a 64-bit hash → hex. Stable, dependency-free, identical on Mac and
    /// iOS so a fingerprint computed on the phone matches the Mac's recompute.
    private static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Parse one line and return (number, hasMarker) if it looks like a
    /// Claude numbered-prompt line. nil otherwise.
    /// Pattern: optional whitespace, optional `❯ ` cursor marker,
    /// digit(s), `.` or `)`, space, body.
    static func parseNumberedLine(_ line: String) -> (Int, Bool)? {
        // Strip ANSI-ish escape sequences (basic: ESC followed by `[`
        // through letter). Claude's prompt is plain UTF-8 in our
        // captures today, but be defensive against future shape changes.
        let cleaned = stripANSI(line).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        var rest = Substring(cleaned)
        var hasMarker = false
        if rest.hasPrefix("❯ ") {
            hasMarker = true
            rest = rest.dropFirst(2)
        } else if rest.hasPrefix("> ") {
            // ASCII fallback — some terminal shells render `>` instead
            // of `❯` when the font lacks the glyph. Treat it the same.
            hasMarker = true
            rest = rest.dropFirst(2)
        }

        // Greedy digit run.
        var digits = ""
        while let c = rest.first, c.isNumber {
            digits.append(c)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let n = Int(digits), n >= 1, n <= 9 else { return nil }

        // Separator: `.` or `)` followed by a space.
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (n, hasMarker)
    }

    private static let ansiPrefix: Character = "\u{1B}"

    /// Strip basic CSI escape sequences (ESC `[` … letter). Not exhaustive
    /// but covers the common color / cursor-position codes Claude emits
    /// inside prompt rendering.
    static func stripANSI(_ s: String) -> String {
        guard s.contains(ansiPrefix) else { return s }
        var out = ""
        var iter = s.makeIterator()
        while let c = iter.next() {
            if c == ansiPrefix {
                guard let next = iter.next() else { break }
                if next == "[" {
                    while let term = iter.next() {
                        if term.isLetter { break }
                    }
                } else {
                    out.append(c)
                    out.append(next)
                }
            } else {
                out.append(c)
            }
        }
        return out
    }
}
