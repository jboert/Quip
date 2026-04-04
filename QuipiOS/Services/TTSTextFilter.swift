import Foundation

/// Filters raw terminal output into speakable prose for TTS readback.
/// Strips ANSI codes, code blocks, diffs, tool-use decorations, and markdown syntax.
enum TTSTextFilter {

    static func filter(_ text: String) -> String {
        var s = text

        // 1. ANSI escape codes
        s = s.replacing(try! Regex(#"\x1b\[[0-9;]*[a-zA-Z]"#), with: "")
        s = s.replacing(try! Regex(#"\x1b\][^\x07]*\x07"#), with: "")

        // 2. Fenced code blocks (``` ... ```)
        s = s.replacing(try! Regex(#"(?ms)```[^\n]*\n.*?```"#), with: "")

        // 3. Indented code blocks — lines starting with 4+ spaces or tab that look like code
        let codePatterns = #"[{}()]|=>|->|import |def |fn |class |let |var |const "#
        s = s.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let l = String(line)
            guard l.hasPrefix("    ") || l.hasPrefix("\t") else { return true }
            return l.range(of: codePatterns, options: .regularExpression) == nil
        }.joined(separator: "\n")

        // 4. Diff lines
        s = s.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let l = String(line)
            if l.hasPrefix("+++ ") || l.hasPrefix("--- ") || l.hasPrefix("@@ ") { return false }
            if (l.hasPrefix("+") || l.hasPrefix("-")), l.count > 1 {
                let rest = String(l.dropFirst())
                if rest.range(of: codePatterns, options: .regularExpression) != nil { return false }
            }
            return true
        }.joined(separator: "\n")

        // 5. File path lines (e.g. src/foo/bar.rs:123 or /path/to/file)
        s = s.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            // Match lines that are just a file path (with optional line number)
            if trimmed.range(of: #"^/?[\w./-]+\.\w+(:\d+)?$"#, options: .regularExpression) != nil {
                return false
            }
            return true
        }.joined(separator: "\n")

        // 6. Tool use markers
        s = s.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            let first = trimmed.unicodeScalars.first!
            // ⏺ U+23FA, │ U+2502, ├ U+251C, └ U+2514
            return first != UnicodeScalar(0x23FA) &&
                   first != UnicodeScalar(0x2502) &&
                   first != UnicodeScalar(0x251C) &&
                   first != UnicodeScalar(0x2514)
        }.joined(separator: "\n")

        // 7. Markdown syntax
        // Headers: strip leading #
        s = s.replacing(try! Regex(#"(?m)^#{1,6}\s+"#), with: "")
        // Bold
        s = replaceCapture(in: s, pattern: #"\*\*(.+?)\*\*"#)
        // Italic
        s = replaceCapture(in: s, pattern: #"\*(.+?)\*"#)
        // Inline code
        s = replaceCapture(in: s, pattern: #"`([^`]+)`"#)
        // Bullet markers
        s = s.replacing(try! Regex(#"(?m)^[\-\*]\s+"#), with: "")

        // Numbered list markers: "1. " etc
        s = s.replacing(try! Regex(#"(?m)^\d+\.\s+"#), with: "")

        // 8. Multiple blank lines → single blank line
        s = s.replacing(try! Regex(#"\n{3,}"#), with: "\n\n")

        // 9. Trim
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        return s
    }

    /// Replace regex matches with their first capture group
    private static func replaceCapture(in string: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        let range = NSRange(location: 0, length: (string as NSString).length)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: "$1")
    }
}
