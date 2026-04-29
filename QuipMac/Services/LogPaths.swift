import Foundation

/// Canonical on-disk locations for Quip's append-only diagnostic logs.
///
/// These used to live in `/tmp/`, which is world-readable on shared hosts and
/// gets wiped on reboot — taking the breadcrumbs that explain "what happened
/// last time" with it. They now live under Apple's `~/Library/Logs/Quip/`
/// convention, which `Console.app` indexes and which survives reboots.
///
/// Each accessor calls `ensureDirectoryExists()` on read, so the first writer
/// to touch a path creates the parent directory. Failures are swallowed — a
/// logger that crashes the app on a disk-full event isn't doing its job.
enum LogPaths {
    /// Parent directory for all Quip logs.
    static var directory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return base.appendingPathComponent("Logs/Quip", isDirectory: true)
    }

    /// APNs push pipeline diagnostics. The "I didn't get a notification"
    /// debugging path lands here.
    static var pushPath: String {
        ensureDirectoryExists()
        return directory.appendingPathComponent("push.log").path
    }

    /// WebSocket handshake and message-arrival breadcrumbs. The
    /// "photo upload spins forever" debugging path lands here — see
    /// CLAUDE.md for the full pipeline checklist.
    static var webSocketPath: String {
        ensureDirectoryExists()
        return directory.appendingPathComponent("websocket.log").path
    }

    /// Kokoro TTS daemon lifecycle and synth events.
    static var kokoroPath: String {
        ensureDirectoryExists()
        return directory.appendingPathComponent("kokoro.log").path
    }

    private static func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
