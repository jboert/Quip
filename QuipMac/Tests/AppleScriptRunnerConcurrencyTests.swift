import XCTest
@testable import Quip

/// Regression cover for the 2026-07-12 crash: `EXC_BAD_ACCESS` inside
/// `TASLexer::EndUse()` while `WindowManager.fetchSubtitles()` compiled a script
/// on the global utility queue and `ClaudeModeDetector`'s poll compiled another
/// on its own queue. `NSAppleScript` keeps the AppleScript parser/lexer in
/// process-wide shared state, so two concurrent compiles tear it.
///
/// These tests hammer `AppleScriptRunner` from many threads at once. Against the
/// old code (each call site building its own `NSAppleScript`) the same shape
/// segfaults the test runner — a crash here IS the failure signal, which is why
/// the assertions are secondary to the fact that the run survives at all.
///
/// The scripts are pure AppleScript arithmetic/string work: they exercise the
/// lexer and parser (which is where the race lived) without needing iTerm2 or
/// Terminal.app on the machine, so this runs anywhere including CI.
final class AppleScriptRunnerConcurrencyTests: XCTestCase {

    /// Distinct source per iteration so nothing can be served from a compile
    /// cache — every call has to walk the parser, which is the contended state.
    private func source(for n: Int) -> String {
        """
        set acc to 0
        repeat with i from 1 to \(n % 7 + 1)
            set acc to acc + i
        end repeat
        return "run-\(n):" & (acc as string)
        """
    }

    private func expected(for n: Int) -> String {
        let bound = n % 7 + 1
        let acc = (1...bound).reduce(0, +)
        return "run-\(n):\(acc)"
    }

    func test_concurrentRuns_fromManyQueues_doNotCrashAndAllSucceed() {
        let iterations = 200
        let results = ResultBox()

        // .concurrent on purpose: this is the exact multi-thread pressure that
        // used to reach NSAppleScript unserialized.
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let output = AppleScriptRunner.run(self.source(for: i))
            results.record(index: i, errorMessage: output.errorMessage, value: output.stringValue)
        }

        XCTAssertEqual(results.count, iterations, "every concurrent run must return")
        for i in 0..<iterations {
            XCTAssertNil(results.error(i), "run \(i) errored: \(results.error(i) ?? "")")
            XCTAssertEqual(results.value(i), expected(for: i), "run \(i) returned the wrong value")
        }
    }

    /// The real-world shape: the two background pollers overlapping a main-thread
    /// keystroke injection. Main blocks on the serial queue rather than racing it.
    func test_mainThreadRun_whileBackgroundQueuesHammer_staysCorrect() {
        let backgroundDone = expectation(description: "background pollers finished")
        backgroundDone.expectedFulfillmentCount = 2

        for queueIndex in 0..<2 {
            DispatchQueue.global(qos: .utility).async {
                for i in 0..<40 {
                    let n = 1_000 + queueIndex * 100 + i
                    let output = AppleScriptRunner.run(self.source(for: n))
                    XCTAssertNil(output.errorMessage)
                    XCTAssertEqual(output.stringValue, self.expected(for: n))
                }
                backgroundDone.fulfill()
            }
        }

        // Meanwhile, on this (main) thread — the keystroke-injection path.
        for i in 0..<40 {
            let output = AppleScriptRunner.run(source(for: i))
            XCTAssertNil(output.errorMessage)
            XCTAssertEqual(output.stringValue, expected(for: i))
        }

        wait(for: [backgroundDone], timeout: 120)
    }

    /// A script that fails to compile must surface an error, not take the queue
    /// down with it — the serial queue is shared by every AppleScript in the app.
    func test_malformedScript_returnsErrorAndQueueKeepsWorking() {
        // Malformed WITHOUT naming an application: compiling `tell application
        // "iTerm2"` makes OSA resolve the app, and on a machine without iTerm
        // (every CI runner) that raises the modal "Where is iTerm2?" picker —
        // headless, nobody answers, and the suite hangs to the job timeout
        // (observed: 28 minutes stuck in this test before cancellation). The
        // file's header rule applies: no app references, parser work only.
        let bad = AppleScriptRunner.run("this is not applescript at all —")
        XCTAssertNotNil(bad.errorMessage, "a malformed script should report an error")

        let good = AppleScriptRunner.run(source(for: 3))
        XCTAssertNil(good.errorMessage, "the queue must still run scripts after a failure")
        XCTAssertEqual(good.stringValue, expected(for: 3))
    }

    // MARK: - offMain: unblock main WITHOUT unserializing the scripts

    /// The invariant the whole file exists for, asserted directly rather than
    /// inferred from "it didn't crash": across every entry point, under every
    /// kind of concurrent pressure, no two scripts are ever inside
    /// `NSAppleScript` at once. `offMain` added a second *waiting* path — this
    /// proves it did not add a second *executing* one.
    func test_runAndOffMain_mixedUnderPressure_neverExecuteTwoScriptsAtOnce() async {
        await withTaskGroup(of: Void.self) { group in
            // The @MainActor-style path: awaits, never blocks.
            for i in 0..<40 {
                group.addTask {
                    let output = await AppleScriptRunner.offMain { AppleScriptRunner.run(self.source(for: i)) }
                    XCTAssertEqual(output.stringValue, self.expected(for: i))
                }
            }
            // The off-main polling path, still synchronous, still hammering.
            for i in 40..<80 {
                group.addTask {
                    let output = await withCheckedContinuation { (c: CheckedContinuation<AppleScriptRunner.Output, Never>) in
                        DispatchQueue.global(qos: .utility).async {
                            c.resume(returning: AppleScriptRunner.run(self.source(for: i)))
                        }
                    }
                    XCTAssertEqual(output.stringValue, self.expected(for: i))
                }
            }
            await group.waitForAll()
        }

        XCTAssertEqual(AppleScriptRunner.peakConcurrentExecutions, 1,
                       "two AppleScripts compiled at once — this is the torn-lexer crash of 2026-07-12")
    }

    /// The defect `offMain` was added to fix: a main-actor caller used to
    /// `queue.sync` and so waited out everything already queued — the per-window
    /// mode polls, a 1-3s subtitle fetch, or a script wedged on an unresponsive
    /// terminal. Occupy the queue, then check the main actor still gets to run.
    @MainActor
    func test_offMain_doesNotParkTheMainActorBehindAQueuedScript() async {
        let queueOccupied = expectation(description: "the slow background script finished")
        DispatchQueue.global(qos: .utility).async {
            _ = AppleScriptRunner.run("delay 0.6\nreturn \"slow\"")
            queueOccupied.fulfill()
        }
        // Give it time to actually be the one in flight.
        try? await Task.sleep(nanoseconds: 150_000_000)

        let startedWaiting = Date()
        async let queued = AppleScriptRunner.offMain { AppleScriptRunner.run(self.source(for: 1)) }

        // The main actor is back here immediately. `run` in this position would
        // have held it for the remainder of the 0.6s script.
        XCTAssertLessThan(Date().timeIntervalSince(startedWaiting), 0.2,
                          "the main actor must not block on the AppleScript queue")

        let output = await queued
        XCTAssertEqual(output.stringValue, expected(for: 1), "and it still gets its result")
        await fulfillment(of: [queueOccupied], timeout: 10)
    }

    /// A poller asks before it enqueues, because a serial queue has no priority:
    /// a mode poll that queues ahead of a keystroke delays a person who is
    /// waiting on it, and the poll runs again in 2s regardless.
    @MainActor
    func test_isUserScriptPending_isTrueWhileAUserInitiatedScriptIsOutstanding() async {
        XCTAssertFalse(AppleScriptRunner.isUserScriptPending, "nothing outstanding at rest")

        async let running = AppleScriptRunner.offMain { AppleScriptRunner.run("delay 0.4\nreturn \"busy\"") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(AppleScriptRunner.isUserScriptPending,
                      "a poller must be able to see that a user-initiated script is in the way")

        _ = await running
        XCTAssertFalse(AppleScriptRunner.isUserScriptPending, "and that it has cleared")
    }
}

/// Thread-safe collector — `concurrentPerform` writes from every thread at once.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Int: String] = [:]
    private var values: [Int: String] = [:]
    private var recorded = 0

    func record(index: Int, errorMessage: String?, value: String?) {
        lock.lock()
        defer { lock.unlock() }
        recorded += 1
        if let errorMessage { errors[index] = errorMessage }
        if let value { values[index] = value }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func error(_ index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return errors[index]
    }

    func value(_ index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[index]
    }
}
