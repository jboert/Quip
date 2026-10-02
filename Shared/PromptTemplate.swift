import Foundation

/// `{{name}}` placeholders in a prompt body, filled from the target window at
/// send time (Q-34). The Mac does the filling, because only it knows the
/// window's folder, agent and clipboard; the phone uses `variables(in:)` to
/// show which placeholders a prompt carries.
///
/// Rules, each pinned by `PromptTemplateTests`:
/// - A name is a letter or `_`, then letters, digits, `_`, `.` or `-`, with
///   optional spaces inside the braces: `{{ folder }}` == `{{folder}}`.
/// - Names match case-insensitively; values are keyed in lowercase.
/// - An unknown name is left exactly as written. A send never blocks on a
///   variable, and a body that only happens to contain braces passes through.
/// - Expansion is one pass: a value that itself contains `{{x}}` (pasted code,
///   a template in the clipboard) is inserted verbatim, never expanded.
enum PromptTemplate {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_.\-]*)\s*\}\}"#
    )

    /// Lowercased variable names in order of first appearance, deduplicated.
    static func variables(in body: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for match in matches(in: body) {
            let name = match.name
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// `body` with every known placeholder replaced, plus the names that had no
    /// value (left literal), in order of first appearance.
    static func expand(_ body: String, values: [String: String]) -> (text: String, unresolved: [String]) {
        var text = ""
        var unresolved: [String] = []
        var cursor = body.startIndex
        for match in matches(in: body) {
            text += body[cursor..<match.range.lowerBound]
            if let value = values[match.name] {
                text += value
            } else {
                text += body[match.range]
                if !unresolved.contains(match.name) { unresolved.append(match.name) }
            }
            cursor = match.range.upperBound
        }
        text += body[cursor...]
        return (text, unresolved)
    }

    private static func matches(in body: String) -> [(range: Range<String.Index>, name: String)] {
        let ns = NSRange(body.startIndex..., in: body)
        return pattern.matches(in: body, range: ns).compactMap { m in
            guard let whole = Range(m.range, in: body),
                  let name = Range(m.range(at: 1), in: body) else { return nil }
            return (whole, body[name].lowercased())
        }
    }
}
