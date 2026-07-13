import XCTest
@testable import Quip

/// Log-cadence audit (2026-07-13). The swallowed-error sweep made several
/// genuinely-silent failures report — correctly — but put three of those lines
/// on *repeating* paths: the 2.0s window-poll timer, per-window screenshot
/// capture, and per-chunk dictation audio. An unthrottled line on a repeating
/// path is the same disease as a swallowed error wearing a different hat: it
/// buries the real signal, just in noise instead of silence.
///
/// The first attempt at transition-only logging (KeystrokeInjector, b8279bd)
/// got the *idea* right and the *state* wrong: one global "last failure" slot
/// for a path that runs per window. `testFailingWindowDoesNotFlipFlopWithA
/// HealthyOne` is that exact bug — it alternated `.error failed` / `.info
/// recovered` up to 4x/sec, i.e. worse than no dedup AND asserting a recovery
/// that hadn't happened.
final class LogTransitionPolicyTests: XCTestCase {

    // MARK: - The pure decision seam

    func testHealthyStaysQuiet() {
        XCTAssertEqual(LogTransitionPolicy.decide(previous: nil, current: nil), .stayQuiet)
    }

    func testFirstFailureReports() {
        XCTAssertEqual(LogTransitionPolicy.decide(previous: nil, current: "exit 1"), .report)
    }

    func testSameCauseStaysQuiet() {
        XCTAssertEqual(LogTransitionPolicy.decide(previous: "exit 1", current: "exit 1"), .stayQuiet)
    }

    func testChangedCauseReports() {
        XCTAssertEqual(LogTransitionPolicy.decide(previous: "exit 1", current: "exit 5"), .report)
    }

    func testRecoveryReportsOnce() {
        XCTAssertEqual(LogTransitionPolicy.decide(previous: "exit 1", current: nil), .reportRecovery)
    }

    // MARK: - Keyed gate

    /// THE REGRESSION. Window A fails forever while window B captures fine, both
    /// polled continuously. With a single shared slot this alternated report /
    /// recovery on every cycle. Keyed: one line for A, silence thereafter, and
    /// no "recovered" line while A is still broken.
    func testFailingWindowDoesNotFlipFlopWithAHealthyOne() {
        let gate = LogTransitionGate<CGWindowID>()
        var decisions: [LogTransition] = []

        for _ in 0..<50 {
            decisions.append(gate.evaluate(1, cause: "screencapture exited 1"))
            decisions.append(gate.evaluate(2, cause: nil))
        }

        XCTAssertEqual(decisions.filter { $0 == .report }.count, 1,
                       "the broken window must be reported exactly once, not once per poll")
        XCTAssertEqual(decisions.filter { $0 == .reportRecovery }.count, 0,
                       "nothing recovered — a recovery line here would be a lie")
        XCTAssertEqual(gate.reportedCause(1), "screencapture exited 1")
        XCTAssertNil(gate.reportedCause(2))
    }

    /// Proof that the *keying* is what fixes it, not the transition idea alone:
    /// route the same two windows through ONE shared key — which is exactly what
    /// the single global `lastCaptureFailure` static did — and the identical
    /// traffic degenerates into a report/recovery flip-flop, ~100 lines where the
    /// keyed gate writes 1.
    func testSharedKeyReproducesTheFlipFlopFlood() {
        let gate = LogTransitionGate<String>()
        var decisions: [LogTransition] = []
        for _ in 0..<50 {
            decisions.append(gate.evaluate("global", cause: "screencapture exited 1")) // window A
            decisions.append(gate.evaluate("global", cause: nil))                      // window B
        }
        XCTAssertEqual(decisions.filter { $0 == .report }.count, 50)
        XCTAssertEqual(decisions.filter { $0 == .reportRecovery }.count, 50)
        XCTAssertEqual(decisions.filter { $0 == .stayQuiet }.count, 0,
                       "a shared slot never stays quiet — it is worse than no dedup at all")
    }

    /// Two windows failing the SAME way are two reports (one each), and still
    /// only one each — the cause string carries no window-identifying data, so
    /// the per-key comparison is what separates them, not the text.
    func testIdenticalCauseOnTwoWindowsReportsOncePerWindow() {
        let gate = LogTransitionGate<CGWindowID>()
        var reports = 0
        for _ in 0..<20 {
            for window in CGWindowID(1)...CGWindowID(2) where
                gate.evaluate(window, cause: "screencapture exited 0 but wrote no file") == .report {
                reports += 1
            }
        }
        XCTAssertEqual(reports, 2)
    }

    /// The 2.0s-timer shape: a permanently unreadable project root (unmounted
    /// volume, TCC-restricted ~/Documents) is hit ~43,000 times a day.
    func testPersistentCauseOnAPollingPathReportsOnce() {
        let gate = LogTransitionGate<String>()
        let reports = (0..<43_200).filter {  _ in
            gate.evaluate("/Volumes/gone", cause: "The folder doesn’t exist.") == .report
        }.count
        XCTAssertEqual(reports, 1)
    }

    func testCauseChangeReportsAgainThenGoesQuiet() {
        let gate = LogTransitionGate<String>()
        XCTAssertEqual(gate.evaluate("root", cause: "no such folder"), .report)
        XCTAssertEqual(gate.evaluate("root", cause: "no such folder"), .stayQuiet)
        XCTAssertEqual(gate.evaluate("root", cause: "permission denied"), .report)
        XCTAssertEqual(gate.evaluate("root", cause: "permission denied"), .stayQuiet)
    }

    func testRecoveryIsAnnouncedOnceAndReFailureReportsAgain() {
        let gate = LogTransitionGate<String>()
        XCTAssertEqual(gate.evaluate("root", cause: "no such folder"), .report)
        XCTAssertEqual(gate.evaluate("root", cause: nil), .reportRecovery)
        XCTAssertEqual(gate.evaluate("root", cause: nil), .stayQuiet)
        XCTAssertEqual(gate.evaluate("root", cause: "no such folder"), .report,
                       "a cause that comes back is news again")
    }

    /// Recovery must drop the key, or a long-lived per-window/per-session gate
    /// grows without bound.
    func testRecoveryReleasesTheKey() {
        let gate = LogTransitionGate<String>()
        _ = gate.evaluate("a", cause: "boom")
        _ = gate.evaluate("b", cause: "boom")
        XCTAssertEqual(gate.failingKeyCount, 2)
        _ = gate.evaluate("a", cause: nil)
        XCTAssertEqual(gate.failingKeyCount, 1)
    }

    /// One PTT press = one drifted stream = many chunks, all failing the same
    /// way. That is one line, and a second press is a second session.
    func testAudioChunkStreamCostsOneLinePerSession() {
        let gate = LogTransitionGate<String>()
        let drift = "keyNotFound(CodingKeys(stringValue: \"pcmBase64\"))"
        var reports = 0
        for session in ["press-1", "press-2"] {
            for _ in 0..<200 where gate.evaluate(session, cause: drift) == .report {
                reports += 1
            }
        }
        XCTAssertEqual(reports, 2)
    }

    /// The gate is read from the Network.framework queue and main alike.
    func testConcurrentEvaluationIsSerialized() {
        let gate = LogTransitionGate<Int>()
        let reports = NSCounter()
        DispatchQueue.concurrentPerform(iterations: 500) { i in
            if gate.evaluate(i % 5, cause: "boom") == .report { reports.increment() }
        }
        XCTAssertEqual(reports.value, 5, "five keys, one report each, however they interleave")
    }
}

/// Tiny thread-safe counter for the concurrency test.
private final class NSCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
