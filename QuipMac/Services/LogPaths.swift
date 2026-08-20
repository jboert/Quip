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
    /// Default ceiling for a single diagnostic log. Past this, the file is
    /// rolled to `<path>.1` and a fresh one starts. One generation is kept:
    /// these are debugging breadcrumbs, not an audit trail, and `push.log`
    /// had reached 231 MB unbounded.
    static let maxLogBytes = 16 * 1024 * 1024

    /// Roll `path` to `path + ".1"` when it exceeds `maxBytes`. Any previous
    /// `.1` is replaced. Returns true when a rotation happened.
    ///
    /// Failures are swallowed, consistent with the rest of this file: a logger
    /// must never take the app down. If the move fails the file simply keeps
    /// growing, which is the status quo.
    @discardableResult
    static func rotateIfNeeded(path: String, maxBytes: Int = maxLogBytes) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              size > maxBytes else { return false }

        let rolled = path + ".1"
        try? fm.removeItem(atPath: rolled)
        do {
            try fm.moveItem(atPath: path, toPath: rolled)
            return true
        } catch {
            return false
        }
    }

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

    /// CLI classification decisions — one line per on-demand `refreshCLIKind`
    /// (the just-in-time path PTT/send_text and image_upload take right before
    /// routing input). Records the chosen `CLIKind`, the prior cached kind, and
    /// the raw process `comm` list the classifier saw. This is the missing
    /// "why did voice land in the wrong place / nowhere" breadcrumb: a line
    /// reading `chosen=shell comms=[zsh|grok]` proves the classifier saw grok
    /// but returned shell (classifier bug), vs `comms=[zsh]` (process-tree walk
    /// missed the agent → stale PID), vs `chosen=grok` (paste/inject is at
    /// fault, not classification). One line per user action, not per poll.
    static var classifyPath: String {
        ensureDirectoryExists()
        return directory.appendingPathComponent("classify.log").path
    }

    private static func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
