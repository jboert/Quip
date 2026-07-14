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
///
/// Serialization does NOT license blocking the main thread on the queue, and the
/// first cut of this file did exactly that (`queue.sync` from the @MainActor
/// injection paths). A serial queue is strict FIFO, so main then waited out
/// every script already on it: one `readContent` per tracked window every 2s,
/// plus a subtitle fetch the code itself documents as taking 1-3 seconds — and,
/// in the worst case, an in-flight script parked on an unresponsive iTerm2 or on
/// the first-run "Quip wants to control iTerm2" consent dialog, which holds the
/// queue for the whole AppleEvent timeout. The menu bar froze and macOS marked
/// Quip "Not Responding". `offMain` is the fix: main-actor callers await, they
/// do not block. The scripts themselves still run one at a time, on `queue`,
/// which is the property the whole file exists for.
enum AppleScriptRunner {
    /// Serial by construction — no `.concurrent` attribute. `.userInitiated` so
    /// a keystroke injection waiting behind a poll isn't starved.
    ///
    /// EVERY `NSAppleScript` execution in the app happens here, and nothing else
    /// may execute one. A second queue would be a second compile.
    private static let queue = DispatchQueue(label: "quip.applescript", qos: .userInitiated)

    /// Where an `offMain` caller's *wait* is parked.
    ///
    /// It cannot be `queue`: the work submitted here calls `run`, which is
    /// `queue.sync`, and dispatching `sync` onto the queue you are already
    /// running on deadlocks. This queue never touches `NSAppleScript` — it only
    /// blocks until `queue` has finished a script — so it cannot put a second
    /// compile in flight. Serial, so a burst of taps parks one thread rather
    /// than one thread each.
    private static let waiters = DispatchQueue(label: "quip.applescript.waiter", qos: .userInitiated)

    /// Scripts submitted through `offMain` — i.e. user-initiated ones, since
    /// that is the only path the @MainActor call sites take — that haven't
    /// finished yet. The background pollers read this and yield.
    ///
    /// A keystroke is latency-critical (someone is holding a phone, waiting for
    /// it) and a 2s mode poll is not, but a serial queue has no notion of
    /// priority: whatever is already enqueued runs first. The only way to keep a
    /// poll out of a keystroke's way is for the poll not to enqueue, so it asks.
    nonisolated private static let pendingLock = NSLock()
    nonisolated(unsafe) private static var pendingUserScripts = 0

    /// True while a user-initiated script is queued or running. A poller that
    /// sees this should skip the rest of its pass — it runs again in 2s, and the
    /// person waiting on the keystroke does not.
    static var isUserScriptPending: Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingUserScripts > 0
    }

    /// Extracted values, not the live descriptor: `NSAppleEventDescriptor` is
    /// not `Sendable` and has no business escaping the queue that produced it —
    /// and `offMain` carries this across a continuation.
    struct Output: Sendable {
        let stringValue: String?
        let booleanValue: Bool
        /// The human-readable AppleScript error, if the script failed.
        let errorMessage: String?

        var failed: Bool { errorMessage != nil }
    }

    /// Compile and run `source`, blocking the caller until it finishes.
    ///
    /// OFF-MAIN CALLERS ONLY. On the main thread this blocks behind the entire
    /// queue, not just its own script — see the type comment for what that costs.
    /// A @MainActor caller wants `offMain`.
    static func run(_ source: String) -> Output {
        queue.sync { execute(source) }
    }

    /// Await, off the main thread, work that runs AppleScript through `run`.
    ///
    /// This moves the *waiting*, not the *running*: `body` still reaches
    /// `NSAppleScript` through the one serial queue, so two scripts still cannot
    /// compile at once. What changes is that a phone `send_text` no longer parks
    /// the main thread behind five queued mode polls (or behind a consent dialog
    /// nobody has answered yet) with the UI frozen the whole time.
    /// `run` for a @MainActor caller with nothing to wrap: awaits instead of
    /// blocking, same serial queue underneath.
    static func runOffMain(_ source: String) async -> Output {
        await offMain { run(source) }
    }

    static func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        beginUserScript()
        let value: T = await withCheckedContinuation { continuation in
            waiters.async {
                continuation.resume(returning: body())
            }
        }
        endUserScript()
        return value
    }

    private static func beginUserScript() {
        pendingLock.lock()
        pendingUserScripts += 1
        pendingLock.unlock()
    }

    private static func endUserScript() {
        pendingLock.lock()
        pendingUserScripts -= 1
        pendingLock.unlock()
    }

    /// The most executions ever seen inside `execute` at the same time. It must
    /// be 1, forever: 2 means two compiles raced and the shared lexer is torn
    /// (`TASLexer::EndUse()`). Measured rather than merely argued, and left in
    /// release builds — the whole file rests on this one invariant, and an
    /// invariant nobody checks is an invariant that quietly stops holding. Two
    /// locked increments against a 50-500ms AppleEvent is free.
    nonisolated(unsafe) private static var executing = 0
    nonisolated(unsafe) private static var peak = 0

    static var peakConcurrentExecutions: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return peak
    }

    /// The only `NSAppleScript` execution in the process. Callers reach it
    /// through `run`, which is what confines it to `queue`.
    private static func execute(_ source: String) -> Output {
        enterExecution()
        defer { exitExecution() }

        guard let script = NSAppleScript(source: source) else {
            return Output(stringValue: nil, booleanValue: false,
                          errorMessage: "Failed to create NSAppleScript")
        }
        var error: NSDictionary?
        let descriptor: NSAppleEventDescriptor? = script.executeAndReturnError(&error)
        let message: String? = error.map {
            $0[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        }
        return Output(stringValue: descriptor?.stringValue,
                      booleanValue: descriptor?.booleanValue ?? false,
                      errorMessage: message)
    }

    private static func enterExecution() {
        pendingLock.lock()
        executing += 1
        peak = max(peak, executing)
        pendingLock.unlock()
    }

    private static func exitExecution() {
        pendingLock.lock()
        executing -= 1
        pendingLock.unlock()
    }
}
