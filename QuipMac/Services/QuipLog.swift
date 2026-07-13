import Foundation

/// The single reporting path for Quip's diagnostic logs.
///
/// Before this existed, every site invented its own `print`, and — worse —
/// benign events were written with the same alarming wording as real failures.
/// A `LatencyProbeService` TCP probe closing normally logged `Connection
/// FAILED: reset by peer` once a minute, which sent a debugging session chasing
/// a dual-backend deadlock that did not exist. Severity is what makes a log
/// readable: `[INFO]` is "this happened", `[ERROR]` is "this broke".
enum QuipLog {

    enum Severity: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    // Multiple subsystems write concurrently — WebSocketServer logs from the
    // Network.framework queue while others log from main — so seek-then-write
    // must be serialized or lines interleave/get lost. Same blessed pattern as
    // KeystrokeInjector.clipboardLock: a Sendable, immutable NSLock providing
    // the actual synchronization for the manual, unsafe-annotated state below.
    nonisolated private static let writeLock = NSLock()

    // ISO8601DateFormatter is expensive to construct and thread-safe to use
    // for formatting, so it's built once and reused rather than allocated on
    // every `line()` call — this becomes a hot path once every subsystem
    // routes through it.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    /// Pure formatter — kept separate from the file write so it can be tested
    /// without touching the disk.
    static func line(severity: Severity, subsystem: String, message: String) -> String {
        let ts = isoFormatter.string(from: Date())
        return "[\(ts)] [\(severity.rawValue)] [\(subsystem)] \(message)\n"
    }

    /// Append one line to `path`, creating the file if it doesn't exist.
    /// Write failures are swallowed on purpose: a logger that crashes the app
    /// on a disk-full event isn't doing its job. This uses the throwing
    /// `FileHandle` APIs deliberately — the legacy `write(_:)` /
    /// `seekToEndOfFile()` methods raise an uncatchable Objective-C
    /// NSException on failure (Swift do/try/catch cannot intercept it), which
    /// would kill the process on exactly the disk-full case this promises to
    /// survive.
    static func write(severity: Severity, subsystem: String, message: String, to path: String) {
        let text = line(severity: severity, subsystem: subsystem, message: message)
        let data = Data(text.utf8)

        writeLock.lock()
        defer { writeLock.unlock() }

        guard let fh = FileHandle(forWritingAtPath: path) else {
            // File doesn't exist yet (or truly can't be opened for writing).
            // Best-effort create; if this also fails, swallow it — that's
            // the whole point of this logger.
            _ = FileManager.default.createFile(atPath: path, contents: data)
            return
        }
        defer { try? fh.close() }

        do {
            try fh.seekToEnd()
            try fh.write(contentsOf: data)
        } catch {
            // Swallow on purpose: a logger that crashes the app on a
            // disk-full/EIO event isn't doing its job.
        }
    }
}
