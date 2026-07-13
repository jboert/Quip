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
}
