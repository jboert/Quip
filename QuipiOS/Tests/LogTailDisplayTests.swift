import XCTest
@testable import Quip

/// Locks the "Mac log tail" section's rendering contract on
/// `ConnectionDiagnosticsSheet` (Task 5, Finding 1).
///
/// The bug: the failure branch used to be gated on `logTailText.isEmpty`, so
/// a refresh that timed out while stale tail text from an earlier successful
/// fetch was still on screen rendered NOTHING — the stale text just sat
/// there with no indication the refresh had failed. The user could not tell
/// "Mac returned identical logs" from "Mac never answered". `logTailDisplay`
/// must surface the failure whenever one exists, regardless of whether text
/// is present.
final class LogTailDisplayTests: XCTestCase {

    typealias Display = ConnectionDiagnosticsSheet.LogTailDisplay

    func test_inFlightWithNoText_showsFetching() {
        let display = ConnectionDiagnosticsSheet.logTailDisplay(
            isInFlight: true, failureMessage: nil, textIsEmpty: true)
        XCTAssertEqual(display, .fetching)
    }

    func test_inFlightWithStaleText_doesNotShowFetching() {
        // A refresh in flight while stale text is present must fall through
        // to the content branch (the header spinner already communicates
        // "fetching"; this section keeps showing the stale tail).
        let display = ConnectionDiagnosticsSheet.logTailDisplay(
            isInFlight: true, failureMessage: nil, textIsEmpty: false)
        XCTAssertEqual(display, .content(failure: nil))
    }

    func test_failureWithNoText_showsFailureOnly() {
        let display = ConnectionDiagnosticsSheet.logTailDisplay(
            isInFlight: false, failureMessage: "Mac didn't respond in 10s — Check the connection and try again",
            textIsEmpty: true)
        XCTAssertEqual(display, .failureOnly("Mac didn't respond in 10s — Check the connection and try again"))
    }

    func test_noRequestYetNoText_showsEmptyState() {
        let display = ConnectionDiagnosticsSheet.logTailDisplay(
            isInFlight: false, failureMessage: nil, textIsEmpty: true)
        XCTAssertEqual(display, .empty)
    }

    func test_successWithText_showsContentWithNoFailure() {
        let display = ConnectionDiagnosticsSheet.logTailDisplay(
            isInFlight: false, failureMessage: nil, textIsEmpty: false)
        XCTAssertEqual(display, .content(failure: nil))
    }

    /// The regression test for Finding 1: stale text on screen plus a fresh
    /// failure must still produce a non-empty, visible failure — never
    /// silently swallowed because text happens to be present.
    func test_failureWithStaleTextPresent_stillSurfacesTheFailure() {
        let cause = "Mac didn't respond in 10s"
        let nextStep = "Check the connection and try again"
        let failureMessage = "\(cause) — \(nextStep)"

        let display = ConnectionDiagnosticsSheet.logTailDisplay(
            isInFlight: false, failureMessage: failureMessage, textIsEmpty: false)

        guard case .content(let renderedFailure) = display else {
            return XCTFail("expected .content with a failure banner, got \(display)")
        }
        let message = try? XCTUnwrap(renderedFailure)
        XCTAssertFalse((message ?? "").isEmpty,
                        "a failure alongside stale content must still render — this is the bug this test guards")
        XCTAssertTrue(message?.contains(cause) ?? false, "the rendered failure must say what went wrong")
        XCTAssertTrue(message?.contains(nextStep) ?? false, "the rendered failure must say what to do about it")
    }
}
