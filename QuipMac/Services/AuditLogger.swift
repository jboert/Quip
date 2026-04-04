import Foundation

/// Logs remote command activity (send_text, quick_action) to an audit log file.
/// Thread-safe, non-blocking — writes happen on a background serial queue.
enum AuditLogger {

    private static let maxFileSize: UInt64 = 10 * 1024 * 1024 // 10MB
    private static let queue = DispatchQueue(label: "com.quip.audit-logger", qos: .utility)

    private static var logURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/Quip/audit.log")
    }

    private static var rotatedURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/Quip/audit.log.1")
    }

    /// Log a remote command. Call from any thread — write is dispatched to a background queue.
    static func log(messageType: String, clientIdentifier: String, textContent: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let truncated = String(textContent.prefix(200))
        let entry = "[\(timestamp)] client=\(clientIdentifier) type=\(messageType) text=\(truncated)\n"

        queue.async {
            writeEntry(entry)
        }
    }

    private static func writeEntry(_ entry: String) {
        let fm = FileManager.default
        let url = logURL
        let dir = url.deletingLastPathComponent()

        // Create directory with 0700 if needed
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            chmod(dir.path, 0o700)
        }

        // Create file if it doesn't exist
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        // Rotate if over 10MB
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64,
           size > maxFileSize {
            // Simple rotation: delete .1, rename current to .1, create fresh
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: url, to: rotatedURL)
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        // Append entry
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        if let data = entry.data(using: .utf8) {
            handle.write(data)
        }
    }
}
