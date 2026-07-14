import Foundation

/// Collapses a high-frequency failure log down to ONE line per distinct cause.
///
/// The swallowed-error sweep made genuinely-silent failures audible, but several
/// of those `print`s sit on paths that REPEAT (SwiftUI `body`, every TLS
/// handshake, every reconnect) with causes that PERSIST (a corrupt @AppStorage
/// blob, a locked Keychain, a bad pin file). Unlatched, they arrive hundreds of
/// lines per second and bury the very signal they exist to surface — the same
/// disease the sweep was commissioned to cure.
///
/// Semantics are "log once until the CAUSE changes", never "stop logging":
///
///   * `verdict(for:)` says log the first time it sees a cause.
///   * The SAME cause again stays quiet (and counts the suppression, which the
///     next line that does print carries as a suffix, so the log is honest
///     about how loud the failure really was).
///   * A DIFFERENT cause prints — a new failure deserves a fresh verdict.
///   * `noteSuccess()` re-arms, so a failure that returns after a good run is
///     reported again rather than hidden behind the earlier report.
///
/// This generalizes `WhisperAudioSender.didLogConvertFailure` (the one place
/// that already got cadence right) so the stores, the cert-pin loader and the
/// Keychain wrappers can all share the same shape.
final class LogLatch: @unchecked Sendable {

    /// Whether to print, plus how many identical repeats were swallowed since
    /// the previous line — so a flood shows up as a count instead of a flood.
    struct Verdict {
        let shouldLog: Bool
        let suppressedRepeats: Int

        /// Ready to append to a log line: empty in the ordinary case.
        var suffix: String {
            suppressedRepeats > 0
                ? " [+\(suppressedRepeats) identical repeat(s) suppressed since the previous line]"
                : ""
        }
    }

    private let lock = NSLock()
    private var currentCause: String?
    private var suppressed = 0

    init() {}

    /// Ask whether `cause` should be printed now.
    func verdict(for cause: String) -> Verdict {
        lock.lock()
        defer { lock.unlock() }
        if currentCause == cause {
            suppressed += 1
            return Verdict(shouldLog: false, suppressedRepeats: 0)
        }
        let carried = suppressed
        currentCause = cause
        suppressed = 0
        return Verdict(shouldLog: true, suppressedRepeats: carried)
    }

    /// The operation succeeded — forget the latched cause so the same failure
    /// recurring later is reported again.
    func noteSuccess() {
        lock.lock()
        defer { lock.unlock() }
        currentCause = nil
        suppressed = 0
    }

    /// Repeats swallowed since the current cause was printed (diagnostics/tests).
    var suppressedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return suppressed
    }

    /// A STABLE identity for an error, for use as a latch key.
    ///
    /// The rule, which the whole tree follows: interpolating a Cocoa `NSError`
    /// is NOT stable — `"\(error)"` renders its `userInfo` dictionary, whose key
    /// order varies call to call, so the SAME fault yields different strings. A
    /// latch keyed on that silently degrades into no latch at all, which is
    /// exactly the flood this type exists to stop. Key an NSError on its shape —
    /// domain + code.
    ///
    /// The trap is that this reaches errors that are not themselves an NSError:
    /// `DecodingError.dataCorrupted` from JSONDecoder carries the
    /// `JSONSerialization` NSError in its context and renders it too (measured:
    /// 200 identical corrupt-JSON failures → 2 distinct strings). Swift's own
    /// `typeMismatch` / `keyNotFound` / `valueNotFound` interpolate stably, but
    /// no call site should have to reason about which case it will get.
    ///
    /// So key on the fault's shape: the DecodingError case, the coding path, and
    /// the context's own (stable) debug description — falling back to the
    /// NSError domain/code pair for everything else. QuipMac's `StableCause`
    /// applies the identical rule on the Mac side.
    static func fingerprint(of error: Error) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case let DecodingError.keyNotFound(key, ctx):
            return "keyNotFound:\(key.stringValue)@\(path(ctx))"
        case let DecodingError.typeMismatch(type, ctx):
            return "typeMismatch:\(type)@\(path(ctx))"
        case let DecodingError.valueNotFound(type, ctx):
            return "valueNotFound:\(type)@\(path(ctx))"
        case let DecodingError.dataCorrupted(ctx):
            return "dataCorrupted:\(ctx.debugDescription)@\(path(ctx))"
        default:
            let ns = error as NSError
            return "\(ns.domain):\(ns.code)"
        }
    }
}

/// A `LogLatch` per subject, for call sites where several distinct subjects can
/// fail independently and each deserves its own one-shot report — e.g. the
/// Keychain PIN read runs per backend (up to 4), and backend A being broken
/// must not mask backend B's first failure.
final class KeyedLogLatch: @unchecked Sendable {

    private let lock = NSLock()
    private var causes: [String: String] = [:]
    private var suppressed: [String: Int] = [:]

    init() {}

    func verdict(for subject: String, cause: String) -> LogLatch.Verdict {
        lock.lock()
        defer { lock.unlock() }
        if causes[subject] == cause {
            suppressed[subject, default: 0] += 1
            return LogLatch.Verdict(shouldLog: false, suppressedRepeats: 0)
        }
        let carried = suppressed[subject] ?? 0
        causes[subject] = cause
        suppressed[subject] = 0
        return LogLatch.Verdict(shouldLog: true, suppressedRepeats: carried)
    }

    func noteSuccess(for subject: String) {
        lock.lock()
        defer { lock.unlock() }
        causes[subject] = nil
        suppressed[subject] = nil
    }
}
