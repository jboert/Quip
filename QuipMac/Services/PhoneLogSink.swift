import Foundation

/// Formats `phone_log` lines for `~/Library/Logs/Quip/phone.log`. One row per
/// phone line, stamped with the Mac's receive time; the phone's own timestamp
/// stays inside the line. Embedded newlines are flattened so a phone line
/// can never forge extra rows, and both line length and lines per message
/// are capped so a misbehaving phone cannot flood the disk.
enum PhoneLogSink {
    static let maxLinesPerMessage = 200
    static let maxLineLength = 500

    static func format(_ lines: [String], at now: Date) -> String {
        let stamp = now.ISO8601Format()
        return lines.prefix(maxLinesPerMessage).map { raw in
            let flat = SecretRedactor.redact(raw)
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let capped = flat.count > maxLineLength ? String(flat.prefix(maxLineLength)) + "…" : flat
            return "\(stamp) \(capped)\n"
        }.joined()
    }
}
