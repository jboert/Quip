import XCTest
import CoreGraphics
@testable import Quip

/// `focusWindow` has to pick ONE AX element out of an app's window list, and
/// the only key it has is position. These pin the decision itself — which
/// candidate wins, and, just as importantly, when the answer is "none" or "more
/// than one" so the caller can say so instead of doing nothing.
///
/// Measured on a live desk before this existed: of 11 real iTerm / Chrome /
/// Terminal / Finder windows, 5 matched and 6 did not, and two Chrome windows
/// shared an origin. Both outcomes used to be indistinguishable from success.
final class AXWindowMatchTests: XCTestCase {

    private func match(_ target: CGPoint, _ candidates: [CGPoint]) -> WindowManager.AXWindowMatch {
        WindowManager.matchAXWindow(targetOrigin: target, candidates: candidates)
    }

    func testExactOriginMatchesThatCandidate() {
        XCTAssertEqual(match(CGPoint(x: 2179, y: 30),
                             [CGPoint(x: 774, y: 30), CGPoint(x: 2179, y: 30)]),
                       .unique(1))
    }

    /// The window moved a few points between the 2.0s CG poll and the tap.
    /// Inside the tolerance this must still resolve.
    func testOriginWithinToleranceStillMatches() {
        XCTAssertEqual(match(CGPoint(x: 100, y: 100), [CGPoint(x: 108, y: 93)]),
                       .unique(0))
    }

    /// The tolerance is exclusive at exactly 10pt — pinned so a later change to
    /// the bound is a deliberate edit rather than an accident.
    func testOriginExactlyAtTheToleranceDoesNotMatch() {
        XCTAssertEqual(match(CGPoint(x: 100, y: 100), [CGPoint(x: 110, y: 100)]), .none)
    }

    /// The measured majority case: the window moved further than the tolerance,
    /// or its AX element reports somewhere else entirely. Must be reportable,
    /// not silent.
    func testOriginBeyondToleranceMatchesNothing() {
        XCTAssertEqual(match(CGPoint(x: 0, y: 940),
                             [CGPoint(x: 2607, y: 31), CGPoint(x: 2179, y: 30)]),
                       .none)
    }

    func testNoCandidatesMatchesNothing() {
        XCTAssertEqual(match(CGPoint(x: 0, y: 0), []), .none)
    }

    /// Two Chrome windows both reported `cg=(692,56)` on the measured desk.
    /// Taking the first silently is how the wrong window gets raised, so the
    /// ambiguity has to come back as its own answer.
    func testTwoCandidatesInsideToleranceReportAmbiguity() {
        XCTAssertEqual(match(CGPoint(x: 692, y: 56),
                             [CGPoint(x: 692, y: 56), CGPoint(x: 694, y: 58)]),
                       .ambiguous([0, 1]))
    }

    /// Ambiguity is about the tolerance window, not about the whole list — a
    /// third, far-away candidate must not be dragged into the report.
    func testAmbiguityListsOnlyTheCandidatesInsideTheTolerance() {
        XCTAssertEqual(match(CGPoint(x: 0, y: 0),
                             [CGPoint(x: 1, y: 1), CGPoint(x: 900, y: 900), CGPoint(x: 2, y: 0)]),
                       .ambiguous([0, 2]))
    }

    /// Negative coordinates are ordinary on a multi-display desk (a monitor
    /// left of the primary), so the tolerance must be a distance, not a sign
    /// test.
    func testNegativeCoordinatesMatchByDistance() {
        XCTAssertEqual(match(CGPoint(x: -225, y: 66), [CGPoint(x: -228, y: 70)]), .unique(0))
    }
}
