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
        let bad = AppleScriptRunner.run("tell application \"iTerm2\" to this is not applescript")
        XCTAssertNotNil(bad.errorMessage, "a malformed script should report an error")

        let good = AppleScriptRunner.run(source(for: 3))
        XCTAssertNil(good.errorMessage, "the queue must still run scripts after a failure")
        XCTAssertEqual(good.stringValue, expected(for: 3))
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
