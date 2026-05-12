import Foundation

/// Redacts sensitive identifiers from log content before it leaves the user's
/// machine via `DiagnosticsBundle`. Two passes:
///
/// - IPv4 dotted quads → mask last two octets ("192.168.4.34" → "192.168.x.x").
///   Catches LAN ranges (10/8, 172.16/12, 192.168/16) and Tailscale CGNAT
///   (100.64/10) without an allow-list — every IP gets the same treatment.
///   Cheap defense-in-depth: ports stay attached so connection-pair
///   correlation is still possible during triage, but the actual host
///   addressing isn't disclosed.
/// - Hostname → literal substring replace. Caller passes the machine's
///   localized name so we don't re-evaluate it inside the redactor (purer
///   tests, and lets callers pin a placeholder for verification).
enum LogRedactor {

    /// Mask the last two octets of every IPv4 in `text`. Skips matches
    /// where any octet exceeds 255 (false positives on version strings
    /// like "1.2.3.4567").
    static func redactIPv4(_ text: String) -> String {
        let pattern = #"\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsRange = NSRange(text.startIndex..., in: text)
        var result = text
        let matches = regex.matches(in: text, range: nsRange).reversed()
        for match in matches {
            guard let full = Range(match.range, in: result),
                  let r1 = Range(match.range(at: 1), in: result),
                  let r2 = Range(match.range(at: 2), in: result),
                  let r3 = Range(match.range(at: 3), in: result),
                  let r4 = Range(match.range(at: 4), in: result) else { continue }
            let o1 = String(result[r1])
            let o2 = String(result[r2])
            let o3 = String(result[r3])
            let o4 = String(result[r4])
            guard let i1 = Int(o1), let i2 = Int(o2), let i3 = Int(o3), let i4 = Int(o4),
                  i1 <= 255, i2 <= 255, i3 <= 255, i4 <= 255 else { continue }
            result.replaceSubrange(full, with: "\(o1).\(o2).x.x")
        }
        return result
    }

    /// Replace literal occurrences of `hostname` (case-insensitive) with
    /// `<host>`. No-op when the supplied hostname is shorter than 3 chars
    /// to avoid pathological substitutions.
    static func redactHostname(_ text: String, hostname: String) -> String {
        guard hostname.count >= 3 else { return text }
        return text.replacingOccurrences(of: hostname, with: "<host>", options: .caseInsensitive)
    }

    /// Both passes, in the order safe for chaining.
    static func redactAll(_ text: String, hostname: String) -> String {
        return redactHostname(redactIPv4(text), hostname: hostname)
    }
}
