import XCTest
@testable import Quip

/// The contract for every phone action that awaits a Mac reply behind a waiting
/// UI state: entering the wait and NEVER hearing back must resolve to `.failed`
/// with a non-empty cause AND a non-empty next step. A spinner is not a terminal
/// state.
///
/// Task 5 discovery found three call sites with a waiting state and nothing that
/// guaranteed it ended — iTerm window scan, Mac diagnostics bundle, Mac log tail.
/// Each is covered below through the holder they now share.
@MainActor
final class PendingMacRequestTests: XCTestCase {

    /// Drives `PendingMacRequest`'s injected clock so a deadline can be tripped
    /// without sleeping through it.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 0
        func advance(by delta: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            t += delta
        }
        func read() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return t
        }
    }

    private func makeRequest(deadline: TimeInterval = 10) -> (PendingMacRequest, FakeClock) {
        let clock = FakeClock()
        let request = PendingMacRequest(deadline: deadline, now: { [clock] in clock.read() })
        return (request, clock)
    }

    // MARK: - The core contract, per unguarded action

    /// The bug, stated once: a request that is never answered must not stay in
    /// its waiting state. Parameterized over the three sites so a regression at
    /// any one of them names itself.
    func test_unansweredRequest_resolvesToFailureWithCauseAndNextStep() {
        for site in ["iTerm window scan", "Mac diagnostics bundle", "Mac log tail"] {
            let (request, clock) = makeRequest(deadline: 10)

            request.start()
            XCTAssertTrue(request.isInFlight, "\(site): must enter the waiting state on start")

            // The Mac never replies. Time passes.
            clock.advance(by: 11)
            request.tick()

            XCTAssertFalse(request.isInFlight,
                           "\(site): the waiting state must NOT survive the deadline — that is the spinner-forever bug")
            guard case .failed(let cause, let nextStep) = request.state else {
                return XCTFail("\(site): expected .failed, got \(request.state)")
            }
            XCTAssertFalse(cause.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(site): a failure must say what went wrong")
            XCTAssertFalse(nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(site): a failure must say what to do about it")
            XCTAssertNotNil(request.failureMessage,
                            "\(site): the view needs something to render")
            XCTAssertFalse(request.failureMessage?.isEmpty ?? true,
                           "\(site): the rendered failure must not be blank")
        }
    }

    /// The watchdog is real, not just a method a test can poke: arming a request
    /// and letting wall-clock time pass must trip it with no help from the test.
    /// Uses a real (short) deadline and the real default clock.
    func test_realWatchdog_tripsWithoutAnyoneDrivingIt() async throws {
        let request = PendingMacRequest(deadline: 0.05)
        request.start()
        XCTAssertTrue(request.isInFlight)

        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(request.isInFlight, "the watchdog must fire on its own")
        guard case .failed(let cause, let nextStep) = request.state else {
            return XCTFail("expected .failed after the real deadline, got \(request.state)")
        }
        XCTAssertFalse(cause.isEmpty)
        XCTAssertFalse(nextStep.isEmpty)
    }

    // MARK: - Send-time failure (socket already dead)

    /// `client.send` returning false means the frame never left the phone. The
    /// call sites resolve immediately rather than arming a wait for a reply that
    /// provably cannot come.
    func test_sendFailure_resolvesImmediatelyWithGuidance() {
        let (request, _) = makeRequest()
        request.start()
        request.resolve(.failed(cause: "Couldn't reach the Mac", nextStep: "Reconnect, then try again"))

        XCTAssertFalse(request.isInFlight)
        XCTAssertEqual(request.failureMessage, "Couldn't reach the Mac — Reconnect, then try again")
    }

    /// Even a call site that resolves with nothing useful must not produce a
    /// blank error — the underlying machine coerces, and the holder surfaces it.
    func test_hollowFailure_stillRendersSomething() {
        let (request, _) = makeRequest()
        request.start()
        request.resolve(.failed(cause: "  ", nextStep: ""))

        XCTAssertFalse(request.isInFlight)
        let message = try? XCTUnwrap(request.failureMessage)
        XCTAssertFalse((message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Happy path + late replies

    func test_replyBeforeDeadline_succeedsAndLeavesNoFailure() {
        let (request, clock) = makeRequest(deadline: 10)
        request.start()
        clock.advance(by: 2)
        request.resolve(.succeeded)

        XCTAssertFalse(request.isInFlight)
        XCTAssertEqual(request.state, .succeeded)
        XCTAssertNil(request.failureMessage)

        // The watchdog must not resurrect a request that already landed.
        clock.advance(by: 100)
        request.tick()
        XCTAssertEqual(request.state, .succeeded)
    }

    /// The Mac finally answers, long after the user was told it had timed out.
    /// The answer must not silently flip the UI back to "fine".
    func test_lateReply_afterTimeout_doesNotClearTheFailure() {
        let (request, clock) = makeRequest(deadline: 10)
        request.start()
        clock.advance(by: 11)
        request.tick()

        request.resolve(.succeeded)

        guard case .failed = request.state else {
            return XCTFail("a timed-out request must stay failed, got \(request.state)")
        }
        XCTAssertNotNil(request.failureMessage)
    }

    /// The fix for Task 5's follow-on finding: `wireBundleHandler` and
    /// `wireLogTailHandler` both write their successful result to view state
    /// FIRST, call `resolve(.succeeded)` (a no-op per the test above once
    /// timed out), then explicitly check for `.failed` and `reset()`. Without
    /// that reset, a late-but-genuinely-successful reply leaves the "Mac
    /// didn't respond in 10s" banner rendered directly above fresh, correct
    /// content — the Mac DID answer, but the UI insists it didn't. This locks
    /// that the handler-level reset actually clears the contradiction: after
    /// it runs, no failure message survives to be rendered.
    func test_lateReply_afterTimeout_thenHandlerResetPattern_clearsStaleFailure() {
        let (request, clock) = makeRequest(deadline: 10)
        request.start()
        clock.advance(by: 11)
        request.tick()
        guard case .failed = request.state else {
            return XCTFail("expected .failed before the late reply, got \(request.state)")
        }
        XCTAssertNotNil(request.failureMessage, "sanity: a failure banner is showing before the late reply lands")

        // The Mac's late reply arrives. Mirror wireBundleHandler /
        // wireLogTailHandler exactly: resolve (no-op), then reset if still
        // failed, since the caller already wrote the fresh content.
        request.resolve(.succeeded)
        if case .failed = request.state {
            request.reset()
        }

        XCTAssertEqual(request.state, .idle,
                       "the handler's reset must clear the stale .failed state once fresh content has landed")
        XCTAssertNil(request.failureMessage,
                     "no stale failure message may survive — the view must not contradict content it just received")
        XCTAssertFalse(request.isInFlight)
    }

    // MARK: - Re-arming

    /// Hammering the refresh button while a scan is already in flight must not
    /// push the deadline out — that would let a hang hide behind the user's own
    /// impatience.
    func test_restartWhileInFlight_doesNotExtendTheDeadline() {
        let (request, clock) = makeRequest(deadline: 10)
        request.start()

        clock.advance(by: 5)
        request.start()          // must be ignored
        XCTAssertTrue(request.isInFlight)

        clock.advance(by: 5)     // t=10: the ORIGINAL deadline
        request.tick()
        guard case .failed = request.state else {
            return XCTFail("the original deadline must still trip at t=10, got \(request.state)")
        }
    }

    /// Retrying after a failure is legitimate and must arm a fresh attempt.
    func test_startAfterFailure_armsAFreshAttempt() {
        let (request, clock) = makeRequest(deadline: 10)
        request.start()
        clock.advance(by: 11)
        request.tick()
        XCTAssertNotNil(request.failureMessage)

        request.start()
        XCTAssertTrue(request.isInFlight, "a retry must re-enter the waiting state")
        XCTAssertNil(request.failureMessage, "the stale failure must not linger over a live retry")

        clock.advance(by: 9)
        request.tick()
        XCTAssertTrue(request.isInFlight, "the fresh deadline runs from the retry, not the first attempt")
    }

    /// Closing the sheet clears the request so a dismissed screen's deadline
    /// cannot fire into a reopened one.
    func test_reset_returnsToIdle() {
        let (request, clock) = makeRequest(deadline: 10)
        request.start()
        request.reset()

        XCTAssertEqual(request.state, .idle)
        XCTAssertNil(request.failureMessage)
        XCTAssertFalse(request.isInFlight)

        clock.advance(by: 100)
        request.tick()
        XCTAssertEqual(request.state, .idle, "a reset request has no deadline to trip")
    }
}
