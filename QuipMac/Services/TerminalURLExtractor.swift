import Foundation

/// Extracts openable URLs from scraped terminal text to feed the iOS URL tray.
///
/// Mirrors the iOS linkifier's scheme filter (QuipiOS/QuipApp.swift ->
/// `linkifiedTerminalContent`): accept `http(s)://…` and `mailto:…`, reject
/// bare-TLD false positives that `NSDataDetector` happily matches (README.md,
/// Quip.app, etc. — `.md` is Moldova's TLD, `.app` is Google's). Keeping the
/// two rulesets in lockstep is a contract — if iOS ever adds ftp:// or
/// tel:, update both sides and both test suites in the same commit.
enum TerminalURLExtractor {

    /// Returns URLs in document order, de-duplicated by absolute string.
    /// Order matters so the tray matches visual scan order in the terminal.
    static func extract(from raw: String) -> [String] {
        guard !raw.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }

        let ns = raw as NSString
        var seen = Set<String>()
        var ordered: [String] = []

        detector.enumerateMatches(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, let url = match.url else { return }
            let matched = ns.substring(with: match.range)
            let scheme = url.scheme?.lowercased() ?? ""
            let accepted: Bool
            if scheme == "mailto" {
                // NSDataDetector returns bare emails as `mailto:addr@host`;
                // also accept explicit `mailto:` in the source text.
                accepted = true
            } else if scheme == "http" || scheme == "https" {
                // Require the source substring to carry the scheme literally
                // so bare `github.com` doesn't get promoted to a link.
                accepted = matched.hasPrefix("http://") || matched.hasPrefix("https://")
            } else {
                accepted = false
            }
            guard accepted else { return }
            let s = url.absoluteString
            if seen.insert(s).inserted { ordered.append(s) }
        }

        return ordered
    }
}
