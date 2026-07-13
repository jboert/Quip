import XCTest
@testable import Quip

final class InFlightActionTests: XCTestCase {

    func test_startedAction_isInFlight() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        XCTAssertEqual(action.state, .inFlight)
    }

    /// The whole point: an action that never hears back MUST resolve to a
    /// failure with a cause and a next step. It must never sit in .inFlight
    /// forever — that is the spinner-that-never-clears bug.
    func test_actionPastDeadline_resolvesToFailureWithCauseAndNextStep() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        let tripped = action.tick(now: 11)
        XCTAssertTrue(tripped, "the watchdog must trip once past the deadline")
        guard case .failed(let cause, let nextStep) = action.state else {
            return XCTFail("expected .failed, got \(action.state)")
        }
        XCTAssertFalse(cause.isEmpty, "a failure must say what went wrong")
        XCTAssertFalse(nextStep.isEmpty, "a failure must say what to do about it")
    }

    func test_actionBeforeDeadline_staysInFlight() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        XCTAssertFalse(action.tick(now: 9))
        XCTAssertEqual(action.state, .inFlight)
    }

    /// A late reply after the watchdog already tripped must not resurrect the
    /// action — the user has been told it failed.
    func test_lateSuccessAfterTimeout_doesNotResurrect() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        _ = action.tick(now: 11)
        action.resolve(.succeeded)
        guard case .failed = action.state else {
            return XCTFail("a timed-out action must stay failed, got \(action.state)")
        }
    }

    func test_successBeforeDeadline_succeeds() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        action.resolve(.succeeded)
        XCTAssertEqual(action.state, .succeeded)
        XCTAssertFalse(action.tick(now: 99), "a resolved action's watchdog is a no-op")
    }

    // MARK: - Finding 1: .failed(cause:nextStep:) contract is enforced, not just documented

    /// A caller-supplied failure with real text must pass through unchanged.
    func test_resolveFailed_withRealText_passesThrough() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        action.resolve(.failed(cause: "Mac rejected the request", nextStep: "Reconnect and retry"))
        guard case .failed(let cause, let nextStep) = action.state else {
            return XCTFail("expected .failed, got \(action.state)")
        }
        XCTAssertEqual(cause, "Mac rejected the request")
        XCTAssertEqual(nextStep, "Reconnect and retry")
    }

    /// The exact hollow-failure case the finding calls out: a caller passing
    /// empty strings must NOT produce an inactionable terminal state.
    func test_resolveFailed_withEmptyStrings_coercesToNonEmptyDefaults() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        action.resolve(.failed(cause: "", nextStep: ""))
        guard case .failed(let cause, let nextStep) = action.state else {
            return XCTFail("expected .failed, got \(action.state)")
        }
        XCTAssertFalse(cause.isEmpty, "an empty cause must be coerced, not preserved")
        XCTAssertFalse(nextStep.isEmpty, "an empty nextStep must be coerced, not preserved")
    }

    /// Whitespace-only strings are just as hollow as truly empty ones.
    func test_resolveFailed_withWhitespaceOnlyStrings_coercesToNonEmptyDefaults() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        action.resolve(.failed(cause: "   ", nextStep: "\n\t "))
        guard case .failed(let cause, let nextStep) = action.state else {
            return XCTFail("expected .failed, got \(action.state)")
        }
        XCTAssertFalse(cause.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Finding 2: start(at:) must not silently re-arm from .inFlight

    /// A second start() call while already in flight must be a no-op that
    /// preserves the ORIGINAL deadline — otherwise a double-start resets the
    /// clock and can mask a hang indefinitely.
    func test_doubleStart_whileInFlight_preservesOriginalDeadline() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        action.start(at: 5) // must be ignored — must not push the deadline to 15
        XCTAssertEqual(action.state, .inFlight)
        XCTAssertFalse(action.tick(now: 9), "still before the ORIGINAL deadline of 10")
        XCTAssertTrue(action.tick(now: 10), "the original deadline (from t=0) must still trip at t=10")
    }

    /// start(at:) from a terminal state IS a legitimate retry and must arm a
    /// fresh attempt with a fresh deadline.
    func test_start_afterFailure_armsFreshAttempt() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        _ = action.tick(now: 11)
        guard case .failed = action.state else {
            return XCTFail("expected .failed before retry, got \(action.state)")
        }
        action.start(at: 20)
        XCTAssertEqual(action.state, .inFlight, "start() from a terminal state must arm a fresh attempt")
        XCTAssertFalse(action.tick(now: 29), "the fresh deadline runs from t=20, not t=0")
        XCTAssertTrue(action.tick(now: 30), "the fresh deadline must trip at t=30")
    }

    // MARK: - Transitions the original suite missed

    func test_resolve_fromIdle_isNoOp() {
        var action = InFlightAction(deadline: 10)
        action.resolve(.succeeded)
        XCTAssertEqual(action.state, .idle, "resolve() before start() must not move the machine")
    }

    func test_tick_fromIdle_isNoOp() {
        var action = InFlightAction(deadline: 10)
        XCTAssertFalse(action.tick(now: 100), "tick() before start() must never trip")
        XCTAssertEqual(action.state, .idle)
    }
}
