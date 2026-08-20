import XCTest
@testable import Quip

@MainActor
final class TerminalStateDebounceTests: XCTestCase {

    private let w = "window-1"

    // MARK: - Asymmetry

    func test_enteringWaitingForInputNeedsSustainedQuiet() {
        var debounce = TerminalStateDebounce()
        for poll in 1..<TerminalStateDebounce.pollsToEnterWaiting {
            XCTAssertFalse(
                debounce.observe(windowId: w, detected: .waitingForInput, current: .neutral),
                "poll \(poll) must not be enough to declare a prompt")
        }
        XCTAssertTrue(debounce.observe(windowId: w, detected: .waitingForInput, current: .neutral))
    }

    func test_leavingWaitingForInputStaysFast() {
        var debounce = TerminalStateDebounce()
        XCTAssertFalse(debounce.observe(windowId: w, detected: .neutral, current: .waitingForInput))
        XCTAssertTrue(
            debounce.observe(windowId: w, detected: .neutral, current: .waitingForInput),
            "clearing a stale prompt badge must not wait as long as raising one")
    }

    func test_enterIsStrictlySlowerThanExit() {
        XCTAssertGreaterThan(
            TerminalStateDebounce.requiredPolls(from: .neutral, to: .waitingForInput),
            TerminalStateDebounce.requiredPolls(from: .waitingForInput, to: .neutral))
    }

    // MARK: - The measured flap

    /// The 2026-08-18 shape: a busy agent whose CPU crosses the idle threshold
    /// every few polls. Under the old flat threshold of 2 this produced a
    /// transition roughly every other poll; it must now produce none.
    func test_alternatingPollsNeverTransition() {
        var debounce = TerminalStateDebounce()
        var state = TerminalState.neutral
        var transitions = 0
        for poll in 0..<200 {
            // Two quiet polls, then two busy ones — quiet runs shorter than the
            // enter threshold, which is exactly what a working turn looks like.
            let detected: TerminalState = (poll % 4 < 2) ? .waitingForInput : .neutral
            if debounce.observe(windowId: w, detected: detected, current: state) {
                state = detected
                transitions += 1
            }
        }
        XCTAssertEqual(transitions, 0, "a working agent must not badge the phone")
        XCTAssertEqual(state, .neutral)
    }

    func test_aRealPromptStillLandsAndIsBoundedInLatency() {
        var debounce = TerminalStateDebounce()
        var polls = 0
        while !debounce.observe(windowId: w, detected: .waitingForInput, current: .neutral) {
            polls += 1
            XCTAssertLessThan(polls, 12, "a genuine prompt must not be swallowed")
        }
        polls += 1
        XCTAssertEqual(Double(polls) * TerminalStateDebounce.pollInterval, 1.5, accuracy: 0.001)
    }

    // MARK: - Counter hygiene

    func test_aDisagreeingPollRestartsTheRun() {
        var debounce = TerminalStateDebounce()
        for _ in 0..<(TerminalStateDebounce.pollsToEnterWaiting - 1) {
            _ = debounce.observe(windowId: w, detected: .waitingForInput, current: .neutral)
        }
        XCTAssertFalse(debounce.observe(windowId: w, detected: .neutral, current: .neutral),
                       "agreeing with the current state is not a transition")
        XCTAssertFalse(debounce.observe(windowId: w, detected: .waitingForInput, current: .neutral),
                       "the interrupted run must start over, not resume")
    }

    func test_countersAreIndependentPerWindow() {
        var debounce = TerminalStateDebounce()
        for _ in 0..<(TerminalStateDebounce.pollsToEnterWaiting - 1) {
            _ = debounce.observe(windowId: "a", detected: .waitingForInput, current: .neutral)
        }
        XCTAssertFalse(debounce.observe(windowId: "b", detected: .waitingForInput, current: .neutral),
                       "window b must not inherit window a's run")
    }

    func test_forgetDropsAHalfAccumulatedRun() {
        var debounce = TerminalStateDebounce()
        for _ in 0..<(TerminalStateDebounce.pollsToEnterWaiting - 1) {
            _ = debounce.observe(windowId: w, detected: .waitingForInput, current: .neutral)
        }
        debounce.forget(windowId: w)
        XCTAssertFalse(debounce.observe(windowId: w, detected: .waitingForInput, current: .neutral),
                       "an untracked window's run must not survive to bias the next one")
    }

    func test_forgetAllClearsEveryWindow() {
        var debounce = TerminalStateDebounce()
        for _ in 0..<(TerminalStateDebounce.pollsToEnterWaiting - 1) {
            _ = debounce.observe(windowId: "a", detected: .waitingForInput, current: .neutral)
            _ = debounce.observe(windowId: "b", detected: .waitingForInput, current: .neutral)
        }
        debounce.forgetAll()
        XCTAssertFalse(debounce.observe(windowId: "a", detected: .waitingForInput, current: .neutral))
        XCTAssertFalse(debounce.observe(windowId: "b", detected: .waitingForInput, current: .neutral))
    }

    func test_sttTransitionsKeepTheOriginalLatency() {
        XCTAssertEqual(TerminalStateDebounce.requiredPolls(from: .neutral, to: .sttActive),
                       TerminalStateDebounce.pollsDefault)
        XCTAssertEqual(TerminalStateDebounce.requiredPolls(from: .sttActive, to: .neutral),
                       TerminalStateDebounce.pollsDefault)
    }

    func test_requiredSecondsMatchesTheAdvertisedWindow() {
        XCTAssertEqual(TerminalStateDebounce.requiredSeconds(from: .neutral, to: .waitingForInput),
                       1.5, accuracy: 0.001)
        XCTAssertEqual(TerminalStateDebounce.requiredSeconds(from: .waitingForInput, to: .neutral),
                       0.5, accuracy: 0.001)
    }
}
