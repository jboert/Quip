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

    /// Pure formatter — kept separate from the file write so it can be tested
    /// without touching the disk.
    static func line(severity: Severity, subsystem: String, message: String) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
        return "[\(ts)] [\(severity.rawValue)] [\(subsystem)] \(message)\n"
    }

    /// Append one line to `path`, creating the file if it doesn't exist.
    /// Write failures are swallowed on purpose: a logger that crashes the app
    /// on a disk-full event isn't doing its job.
    static func write(severity: Severity, subsystem: String, message: String, to path: String) {
        let text = line(severity: severity, subsystem: subsystem, message: message)
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(text.utf8))
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        }
    }
}
