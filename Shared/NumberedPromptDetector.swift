import Foundation

/// Detects an agent CLI's numbered-prompt block in a terminal content
/// snapshot — the `❯ 1. Yes / 2. No / 3. Cancel` style affordance Claude
/// renders, or the `› 1. Yes` marker Codex can render, when asking the
/// user to pick from a list. (§18.)
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
///      whitespace + known cursor marker OR start-of-line, then a digit,
///      a `.` or `)` separator, a space, then text.
///   3. Require AT LEAST ONE marker-prefixed line in the matched cluster
///      (agent CLIs render the prompt with the cursor marker on the
///      currently highlighted option). Without the marker, treat as
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

    /// Upper bound for dynamic in-app prompt buttons. This keeps accidental
    /// log/prose matches bounded while allowing real multi-choice menus well
    /// beyond notification-action limits.
    static let maxOptionNumber = 99

    /// Detect a numbered prompt block. Returns the contiguous option
    /// numbers (1-based, ascending) or nil when no prompt detected.
    static func detect(in content: String) -> [Int]? {
        bestRun(in: content)?.map(\.number)
    }

    /// True when the detected prompt is a MULTI-SELECT (checkbox) menu — any
    /// option carries a `[ ]`/`[x]` token. The phone renders accumulating
    /// toggles + a Submit button for these instead of one-tap-and-submit, and
    /// the Mac toggles each pick then presses Return once. nil/single-select
    /// prompts return false. (§18.2)
    static func isMultiSelect(in content: String) -> Bool {
        bestRun(in: content)?.contains(where: \.hasCheckbox) ?? false
    }

    /// A `[ ]` / `[x]` / `[X]` / `[✓]` checkbox token anywhere on the line —
    /// the signature of an interactive multi-select option.
    static func lineHasCheckbox(_ line: String) -> Bool {
        let s = stripANSI(line)
        return s.contains("[ ]") || s.contains("[x]") || s.contains("[X]") || s.contains("[✓]")
    }

    private struct Match { let number: Int; let hasMarker: Bool; let hasCheckbox: Bool; let normalized: String; let letter: Character?; let lineIndex: Int }

    /// At most this many non-numbered lines may sit BETWEEN two numbered
    /// options before the run is considered ended. Claude's verbose menus put
    /// several description lines under each option (`rm -rf …`, `Delete only …`),
    /// so a hard "any non-numbered line breaks the run" rule collapsed real
    /// menus down to their first option. Tolerate option bodies up to this many
    /// lines; longer gaps mean the prompt ended (or it was prose).
    private static let maxBodyLinesBetweenOptions = 12

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
        // Non-numbered lines seen since the last option in `current`. An option
        // can carry a multi-line body; only a long run of non-option lines ends
        // the block (see maxBodyLinesBetweenOptions).
        var gap = 0
        func flush() {
            guard current.count > best.count else { return }
            // A cursor marker (`❯`/`›`/`>`) alone proves a live prompt — accept
            // anywhere in the window. A `[ ]`/`[x]` checkbox is just as
            // unambiguous: prose never writes `N. [ ] …`, so a checkbox run is a
            // real (multi-select) prompt. A marker-LESS, checkbox-less run is
            // ambiguous with prose (outlines, rubrics share the `1. A — …`
            // shape), so it only qualifies when ALL of: it's a
            // sequential-lettered block, it sits at the bottom of the viewport,
            // AND a choice cue (`?` / pick / choose / …) precedes it. (§18.1)
            let accepted = current.contains(where: \.hasMarker)
                || current.contains(where: \.hasCheckbox)
                || (isLetteredChoiceRun(current)
                    && isTrailingRun(current, in: tail)
                    && hasChoiceCue(current, in: tail))
            if accepted { best = current }
        }
        for (idx, line) in tail.enumerated() {
            if let (n, marker) = parseNumberedLine(line) {
                let m = Match(number: n, hasMarker: marker, hasCheckbox: lineHasCheckbox(line),
                              normalized: normalizedOptionLine(line),
                              letter: choiceLetter(in: line), lineIndex: idx)
                if let last = current.last, n == last.number + 1 {
                    current.append(m)
                    gap = 0
                } else if n == 1 {
                    // Start of a new candidate block — bank the prior run first
                    // (gap tolerance means body lines no longer flushed it).
                    flush()
                    current = [m]
                    gap = 0
                } else {
                    // Out-of-order numbering — end the prior run, drop this line.
                    flush()
                    current = []
                    gap = 0
                }
            } else if !current.isEmpty {
                // Body line under the current option. Tolerate up to
                // maxBodyLinesBetweenOptions; only a longer gap ends the run
                // (the prompt finished, or this was prose all along).
                gap += 1
                if gap > maxBodyLinesBetweenOptions {
                    flush()
                    current = []
                    gap = 0
                }
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
        if let marker = promptMarkerPrefix(in: s) {
            s.removeFirst(marker.count)
        }
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
        if let run = bestRun(in: content) {
            return fnv1a(run.map(\.normalized).joined(separator: "\n"))
        }
        // y/n prompts have no numbered run; hash the y/n line so press_y /
        // press_n answers can be re-validated uniformly. (§3.2)
        if let yn = yesNoLine(in: content) {
            return fnv1a("yn:" + yn)
        }
        return nil
    }

    /// Detect a free-form yes/no prompt (e.g. "Continue? (y/n)") as opposed to
    /// a numbered list. Guards `press_y`/`press_n` re-validation. (§3.2)
    static func detectYesNo(in content: String) -> Bool {
        yesNoLine(in: content) != nil
    }

    /// The normalized line carrying a `(y/n)` / `(yes/no)` affordance, or nil.
    private static func yesNoLine(in content: String) -> String? {
        guard !content.isEmpty else { return nil }
        for line in content.components(separatedBy: "\n").suffix(scanLineLimit) {
            let s = stripANSI(line).lowercased()
            if s.contains("(y/n)") || s.contains("(yes/no)") {
                return s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            }
        }
        return nil
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
    /// Pattern: optional whitespace, optional known cursor marker,
    /// digit(s), `.` or `)`, space, body.
    static func parseNumberedLine(_ line: String) -> (Int, Bool)? {
        // Strip ANSI-ish escape sequences (basic: ESC followed by `[`
        // through letter). Claude's prompt is plain UTF-8 in our
        // captures today, but be defensive against future shape changes.
        let cleaned = stripANSI(line).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        var rest = Substring(cleaned)
        var hasMarker = false
        if let marker = promptMarkerPrefix(in: String(rest)) {
            hasMarker = true
            rest = rest.dropFirst(marker.count)
        }

        // Greedy digit run.
        var digits = ""
        while let c = rest.first, c.isNumber {
            digits.append(c)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty,
              let n = Int(digits),
              n >= 1,
              n <= maxOptionNumber else { return nil }

        // Separator: `.`, `)`, or `:` followed by a space. The colon form
        // appears in some compact TUI prompt renderers.
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") || rest.hasPrefix(": ") else { return nil }
        return (n, hasMarker)
    }

    /// Extract the single-letter choice label a line carries after its
    /// numbered separator, e.g. `1. A — …` → `A`, or nil when the body
    /// isn't a bare `<Letter><boundary>` label. The letter must be a lone
    /// A–Z immediately followed by a non-alphanumeric boundary so prose
    /// like `1. Add the file` (body starts `Ad…`) is rejected — only a true
    /// label such as `A —` / `A)` / `A.` / `A ` matches. (§18.1)
    static func choiceLetter(in line: String) -> Character? {
        var rest = Substring(stripANSI(line).trimmingCharacters(in: .whitespaces))
        if let marker = promptMarkerPrefix(in: String(rest)) {
            rest = rest.dropFirst(marker.count)
        }
        while let c = rest.first, c.isNumber { rest = rest.dropFirst() }
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") || rest.hasPrefix(": ") else { return nil }
        rest = rest.dropFirst(2)
        while rest.first == " " { rest = rest.dropFirst() }
        guard let letter = rest.first, ("A"..."Z").contains(letter) else { return nil }
        rest = rest.dropFirst()
        // Next char must be a boundary (space / punctuation / end), not a
        // continuation — this is what separates the label `A —` from the
        // word `Add`.
        if let next = rest.first, next.isLetter || next.isNumber { return nil }
        return letter
    }

    /// True when a run is a sequential-lettered choice menu: every line
    /// carries a lone label letter in lockstep with its position (line 1 →
    /// `A`, line 2 → `B`, …). Lets a marker-less block still register as a
    /// real prompt without re-opening the prose false-positive the `❯`
    /// marker requirement otherwise guards against. (§18.1)
    private static func isLetteredChoiceRun(_ run: [Match]) -> Bool {
        guard run.count >= 2 else { return false }
        for (i, m) in run.enumerated() {
            guard let letter = m.letter,
                  let expected = UnicodeScalar(65 + i).map(Character.init),
                  letter == expected else { return false }
        }
        return true
    }

    /// At most this many non-empty lines may follow a marker-less run for it to
    /// count as "trailing" (an agent's question sits at the bottom of the
    /// viewport). An outline embedded mid-reply has prose after it → rejected.
    private static let maxTrailingNonEmptyLines = 2
    /// How many lines above a marker-less run to scan for a choice cue.
    private static let choiceCueLookback = 5
    /// Lowercased substrings that signal the preceding line is *asking* the user
    /// to choose, as opposed to a heading like `Outline:` / `Grading scale:`.
    /// `options` (plural) rather than `option` avoids matching `optional`.
    private static let choiceCueWords = ["pick", "choose", "select", "which",
                                         "prefer", "want to", "would you",
                                         "go with", "consider", "options"]

    /// True when `run` sits at the bottom of the scanned tail — at most
    /// `maxTrailingNonEmptyLines` non-empty lines follow its last option. This
    /// is the strongest discriminator between a real trailing choice prompt and
    /// a lettered outline/rubric embedded earlier in the output. (§18.1)
    private static func isTrailingRun(_ run: [Match], in tail: [String]) -> Bool {
        guard let last = run.last else { return false }
        var nonEmptyAfter = 0
        var i = last.lineIndex + 1
        while i < tail.count {
            if !stripANSI(tail[i]).trimmingCharacters(in: .whitespaces).isEmpty {
                nonEmptyAfter += 1
                if nonEmptyAfter > maxTrailingNonEmptyLines { return false }
            }
            i += 1
        }
        return true
    }

    /// True when a line within `choiceCueLookback` lines above the run *asks*
    /// for a choice — ends with `?` or contains a cue word. Headings like
    /// `Outline:` / `Grading scale:` carry no cue, so lettered prose blocks
    /// that merely look like menus stay out. (§18.1)
    private static func hasChoiceCue(_ run: [Match], in tail: [String]) -> Bool {
        guard let first = run.first else { return false }
        let lo = max(0, first.lineIndex - choiceCueLookback)
        var i = lo
        while i < first.lineIndex {
            let s = stripANSI(tail[i]).trimmingCharacters(in: .whitespaces).lowercased()
            if !s.isEmpty {
                if s.hasSuffix("?") { return true }
                for cue in choiceCueWords where s.contains(cue) { return true }
            }
            i += 1
        }
        return false
    }

    private static let promptMarkers = ["❯ ", "› ", "> "]

    private static func promptMarkerPrefix(in line: String) -> String? {
        promptMarkers.first { line.hasPrefix($0) }
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
