import Foundation

/// The one place in Quip that is allowed to run an `NSAppleScript`.
///
/// `NSAppleScript` is not thread-safe: the OSA component behind it keeps the
/// AppleScript parser and lexer in process-wide shared state, and every
/// `executeAndReturnError` compiles the source first (so even "just running" a
/// script mutates that state). Quip used to drive it from three contexts at
/// once — the window-subtitle/session poll on a global utility queue, the
/// Claude-mode poll on its own queue, and keystroke injection on main. Two
/// 2-second timers on different queues overlap constantly, and a compile racing
/// another compile tears the shared lexer: `EXC_BAD_ACCESS` inside
/// `TASLexer::EndUse()` (crash of 2026-07-12).
///
/// Serializing every execution through one queue removes the race at its
/// source. The FIFO ordering is also what the multi-keystroke paths (e.g. the
/// smart-answer multi-select sequence) already assume.
enum AppleScriptRunner {
    /// Serial by construction — no `.concurrent` attribute. `.userInitiated` so
    /// a keystroke injection waiting behind a poll isn't starved.
    private static let queue = DispatchQueue(label: "quip.applescript", qos: .userInitiated)

    struct Output {
        let descriptor: NSAppleEventDescriptor?
        let error: NSDictionary?

        var stringValue: String? { descriptor?.stringValue }
        var booleanValue: Bool { descriptor?.booleanValue ?? false }

        /// The human-readable AppleScript error, if the script failed.
        var errorMessage: String? {
            guard let error else { return nil }
            return error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        }
    }

    /// Compile and run `source`, blocking the caller until it finishes.
    ///
    /// Callers on the main thread block until any in-flight script completes.
    /// That is the intended trade: a bounded wait behind another script beats a
    /// segfault, and the polls that could hold the queue for a second or more
    /// run off-main anyway.
    static func run(_ source: String) -> Output {
        queue.sync {
            guard let script = NSAppleScript(source: source) else {
                let failure: NSDictionary = [NSAppleScript.errorMessage: "Failed to create NSAppleScript"]
                return Output(descriptor: nil, error: failure)
            }
            var error: NSDictionary?
            let descriptor = script.executeAndReturnError(&error)
            return Output(descriptor: descriptor, error: error)
        }
    }
}
