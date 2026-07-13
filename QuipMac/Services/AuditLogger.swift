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

        // Append entry.
        //
        // This used to `guard ... else { return }` and drop the entry without a
        // sound. An audit log that silently stops auditing is worse than no
        // audit log: it still LOOKS like a record of what happened, so nobody
        // goes looking for the gap. If we cannot write the audit trail, that
        // failure itself has to leave a trace somewhere else.
        //
        // Legacy `FileHandle.write(_:)`/`seekToEndOfFile()` raise an uncatchable
        // ObjC exception on a failed write (disk full) — do/try/catch cannot
        // intercept it and the process dies. The throwing variants can actually
        // be handled, which is the whole point here.
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            guard let data = entry.data(using: .utf8) else { return }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            if auditGate.evaluate("write", cause: nil) == .reportRecovery {
                QuipLog.write(severity: .info, subsystem: "audit",
                              message: "audit log writable again", to: LogPaths.webSocketPath)
            }
        } catch {
            // Gated: a persistent cause (disk full, permissions) fails on EVERY
            // logged command, and this path runs per remote message. Key on the
            // error's SHAPE — interpolating a Cocoa NSError renders its userInfo
            // dictionary, whose key order is not stable, which would make the
            // cause never compare equal and defeat the gate entirely.
            let ns = error as NSError
            guard auditGate.evaluate("write", cause: "\(ns.domain) \(ns.code)") == .report else { return }
            QuipLog.write(
                severity: .error, subsystem: "audit",
                message: "AUDIT ENTRY DROPPED — could not write \(url.lastPathComponent) "
                       + "(\(ns.domain) \(ns.code)). Remote commands are executing but are NOT "
                       + "being recorded. Further identical failures are suppressed.",
                to: LogPaths.webSocketPath
            )
        }
    }

    /// Health of the audit file itself. See the `catch` above: the failure is
    /// per-message and its causes are persistent, so it reports on transitions.
    private static let auditGate = LogTransitionGate<String>()
}
