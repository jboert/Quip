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

    // MARK: - The bound (recovery alone is not one)

    /// The leak recovery cannot close: keys whose subject dies broken never
    /// recover. A CGWindowID that fails capture and then closes is gone (and
    /// never reused); a PTT session whose every chunk fails to decode leaves one
    /// dead key per press. Unbounded, a long-running Quip accumulates them for
    /// as long as the process lives.
    func testKeysThatNeverRecoverAreEvictedAtCapacity() {
        let gate = LogTransitionGate<CGWindowID>(capacity: 8)
        // 200 windows, each failing exactly once and then closing forever.
        for window in CGWindowID(1)...CGWindowID(200) {
            XCTAssertEqual(gate.evaluate(window, cause: "screencapture wrote no file"), .report)
        }
        XCTAssertEqual(gate.failingKeyCount, 8,
                       "the map must be bounded by capacity, not by recoveries that never come")
    }

    /// Eviction is FIFO by first report, and it must not cost the gate its job:
    /// a key still inside the window keeps suppressing.
    func testEvictionDropsTheOldestKeyAndKeepsSuppressingLiveOnes() {
        let gate = LogTransitionGate<String>(capacity: 2)
        XCTAssertEqual(gate.evaluate("old", cause: "boom"), .report)
        XCTAssertEqual(gate.evaluate("mid", cause: "boom"), .report)
        XCTAssertEqual(gate.evaluate("new", cause: "boom"), .report)   // evicts "old"

        XCTAssertNil(gate.reportedCause("old"), "the oldest failing key is the one evicted")
        XCTAssertEqual(gate.reportedCause("mid"), "boom")
        XCTAssertEqual(gate.evaluate("mid", cause: "boom"), .stayQuiet,
                       "a key still on record must keep suppressing after an eviction")
        XCTAssertEqual(gate.evaluate("new", cause: "boom"), .stayQuiet)
        XCTAssertEqual(gate.failingKeyCount, 2)
    }

    /// An evicted key that is STILL broken reports once more — the honest cost
    /// of the bound, and one line, not a flood.
    func testEvictedKeyThatStillFailsReportsAgain() {
        let gate = LogTransitionGate<String>(capacity: 1)
        XCTAssertEqual(gate.evaluate("a", cause: "boom"), .report)
        XCTAssertEqual(gate.evaluate("b", cause: "boom"), .report)     // evicts "a"
        XCTAssertEqual(gate.evaluate("a", cause: "boom"), .report,
                       "an evicted key looks new; it costs one extra line, never a flood")
        XCTAssertEqual(gate.evaluate("a", cause: "boom"), .stayQuiet)
    }

    /// A caller that knows a subject is dead can say so, keeping the map at its
    /// true working size rather than riding the capacity bound.
    func testForgetReleasesADeadSubjectWithoutClaimingRecovery() {
        let gate = LogTransitionGate<String>()
        _ = gate.evaluate("session-1", cause: "audio_chunk failed to decode")
        XCTAssertEqual(gate.failingKeyCount, 1)

        gate.forget("session-1")
        XCTAssertEqual(gate.failingKeyCount, 0)
        XCTAssertNil(gate.reportedCause("session-1"))

        // Forgetting is not a recovery — no line was written for it, so the same
        // failure arriving later is genuinely new.
        XCTAssertEqual(gate.evaluate("session-1", cause: "audio_chunk failed to decode"), .report)
    }

    func testForgetIsANoOpForAKeyThatIsNotFailing() {
        let gate = LogTransitionGate<String>()
        _ = gate.evaluate("a", cause: "boom")
        gate.forget("never-seen")
        XCTAssertEqual(gate.failingKeyCount, 1)
        XCTAssertEqual(gate.reportedCause("a"), "boom")
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

/// The cause string a gate compares is only as good as its stability. This is
/// the trap that silently defeats a transition gate: the cause LOOKS constant
/// for a constant fault, but isn't.
///
/// Interpolating a Cocoa `NSError` renders its `userInfo` dictionary, and
/// dictionary key order is not stable across calls. So `"\(error)"` on an
/// NSError yields a DIFFERENT string each time for the SAME failure — the gate's
/// `cause != previous` check then holds on every call, it never suppresses, and
/// the path it was protecting floods anyway. `captureWindowScreenshot` keys on
/// the error's shape (domain + code) precisely because `process.run()` throws
/// this kind of error.
///
/// The reflex "well, mine is a DecodingError, so interpolation is fine" is the
/// way this bites twice: `DecodingError.dataCorrupted` — what JSONDecoder hands
/// back for a malformed frame — carries the JSONSerialization NSError in its
/// context and renders it, so it inherits exactly the same instability. Hence
/// `StableCause`: every error that reaches a gate is keyed on its shape, and no
/// call site has to reason about which case it will be handed. These tests pin
/// all of it.
final class LogTransitionCauseStabilityTests: XCTestCase {

    private func multiKeyNSError() -> NSError {
        NSError(domain: "TestDomain", code: -1, userInfo: [
            "alpha": 1, "beta": "two", "gamma": [1, 2, 3], "delta": ["k": "v"], "epsilon": 5.0,
        ])
    }

    /// Documents the hazard itself. If a future Foundation makes NSError render
    /// deterministically this test fails — which is a fine reason to revisit the
    /// workaround, and far better than the workaround quietly rotting.
    func testInterpolatedNSErrorIsNotStable() {
        let distinct = Set((0..<50).map { _ in "\(multiKeyNSError())" })
        XCTAssertGreaterThan(
            distinct.count, 1,
            "An interpolated multi-key NSError is expected to be unstable; a gate keyed on it silently never suppresses."
        )
    }

    /// The shape (domain + code) is what a gate must key on for an NSError.
    func testNSErrorShapeIsStable() {
        let distinct = Set((0..<50).map { _ -> String in
            let ns = multiKeyNSError()
            return "\(ns.domain) \(ns.code)"
        })
        XCTAssertEqual(distinct.count, 1, "domain+code must be a stable cause for the same fault")
    }

    /// A gate fed the unstable cause reports every single time — i.e. it is a
    /// no-op. This is the flood, reproduced.
    func testGateKeyedOnInterpolatedNSErrorNeverSuppresses() {
        let gate = LogTransitionGate<String>()
        var reports = 0
        for _ in 0..<50 where gate.evaluate("win", cause: "\(multiKeyNSError())") == .report {
            reports += 1
        }
        XCTAssertGreaterThan(reports, 1, "unstable cause defeats the gate — that is the bug this guards")
    }

    /// The same gate, fed the stable shape, reports exactly once.
    func testGateKeyedOnNSErrorShapeSuppressesAfterFirst() {
        let gate = LogTransitionGate<String>()
        var reports = 0
        for _ in 0..<50 {
            let ns = multiKeyNSError()
            if gate.evaluate("win", cause: "screencapture (\(ns.domain) \(ns.code))") == .report {
                reports += 1
            }
        }
        XCTAssertEqual(reports, 1, "a persistent fault must report once, then stay quiet")
    }

    /// The audio gate's licence: a Swift DecodingError DOES interpolate stably,
    /// so `"\(error)"` suppresses correctly there.
    /// Swift's own DecodingError cases (typeMismatch here) do interpolate stably
    /// — the half of the rule that is true.
    func testDecodingErrorTypeMismatchInterpolatesStablyAndSuppresses() {
        let gate = LogTransitionGate<String>()
        let bad = Data(#"{"not":"an array"}"#.utf8)
        var reports = 0
        for _ in 0..<50 {
            do {
                _ = try JSONDecoder().decode([String].self, from: bad)
            } catch {
                if gate.evaluate("session", cause: "\(error)") == .report { reports += 1 }
            }
        }
        XCTAssertEqual(reports, 1, "typeMismatch has no NSError under it")
    }

    /// The half that is NOT: a genuinely malformed audio_chunk frame decodes to
    /// `dataCorrupted`, whose interpolation renders the JSONSerialization
    /// NSError underneath — so the gate that was supposed to cost one line per
    /// PTT press instead reports repeatedly. This is the flood the audio-chunk
    /// gate was written to prevent, reproduced against the naive cause.
    func testGateKeyedOnInterpolatedCorruptJSONFloods() {
        let gate = LogTransitionGate<String>()
        let bad = Data("not json at all".utf8)
        var reports = 0
        for _ in 0..<200 {
            do {
                _ = try JSONDecoder().decode([String].self, from: bad)
            } catch {
                if gate.evaluate("session", cause: "\(error)") == .report { reports += 1 }
            }
        }
        XCTAssertGreaterThan(reports, 1,
                             "if this ever holds at 1 the platform changed; a gate must not depend on it")
    }

    /// `StableCause` is what the audio-chunk gate actually keys on, and it holds
    /// for every DecodingError case — including the corrupt-JSON one above.
    func testStableCauseSuppressesForEveryDecodingErrorCase() {
        for blob in ["not json at all", #"{"not":"an array"}"#] {
            let gate = LogTransitionGate<String>()
            var reports = 0
            for _ in 0..<200 {
                do {
                    _ = try JSONDecoder().decode([String].self, from: Data(blob.utf8))
                } catch {
                    if gate.evaluate("session", cause: StableCause.text(for: error)) == .report {
                        reports += 1
                    }
                }
            }
            XCTAssertEqual(reports, 1, "one fault, one line — blob: \(blob)")
        }
    }

    /// Different faults must still be told apart, or the gate over-suppresses and
    /// hides the second bug behind the first.
    func testStableCauseDistinguishesDifferentFaults() {
        struct M: Decodable { let a: [String] }
        var causes: [String] = []
        for blob in ["not json at all", #"{"a": 7}"#, "{}"] {
            do {
                _ = try JSONDecoder().decode(M.self, from: Data(blob.utf8))
            } catch {
                causes.append(StableCause.text(for: error))
            }
        }
        XCTAssertEqual(Set(causes).count, 3, "corrupt data, wrong type and a missing key are three faults")
    }

    /// Non-decoding errors fall back to the shape that `captureWindowScreenshot`
    /// already keys on by hand.
    func testStableCauseFallsBackToNSErrorShape() {
        let distinct = Set((0..<50).map { _ in StableCause.text(for: multiKeyNSError()) })
        XCTAssertEqual(distinct.count, 1)
        XCTAssertEqual(StableCause.text(for: multiKeyNSError()), "TestDomain -1")
    }
}
