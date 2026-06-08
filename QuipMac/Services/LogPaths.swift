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

    /// Per-message text-land timing — one line per send_text completion with
    /// the routing path (pasteText / sendText), text length, and Mac-side
    /// processing time. Drives the latency-regression detector + the
    /// in-app diagnostics view.
    static var latencyPath: String {
        ensureDirectoryExists()
        return directory.appendingPathComponent("latency.log").path
    }

    /// Image upload pipeline diagnostics. One line per save/inject/ack/error
    /// so phone-side spinners can be traced without needing Xcode attached.
    static var imageUploadPath: String {
        ensureDirectoryExists()
        return directory.appendingPathComponent("image-upload.log").path
    }

    /// QA mode pair lifecycle: set/clear/lost events + per-tick broadcast
    /// filter counts. One line per event.
    static var qaModePath: String {
        ensureDirectoryExists()
        return directory.appendingPathComponent("qa-mode.log").path
    }

    /// swrm board-integration tailer: per-project event-log tail lifecycle
    /// (start/stop), cursor advances, delivered events, and trigger
    /// firings. One line per event. See the swrm-board-integration PRD.
    static var swrmPath: String {
        ensureDirectoryExists()
        return directory.appendingPathComponent("swrm.log").path
    }

    private static func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
