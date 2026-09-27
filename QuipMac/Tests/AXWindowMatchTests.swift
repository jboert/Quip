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

    // MARK: - Q-22: resolve by position + size + title (public API only)

    private typealias C = WindowManager.AXCandidate

    private func resolve(origin: CGPoint, size: CGSize, title: String,
                         _ candidates: [C]) -> WindowManager.AXWindowMatch {
        WindowManager.resolveAXWindow(
            target: .init(origin: origin, size: size, title: title), candidates: candidates)
    }

    /// The measured desk: Chrome 1710 and 1711 both at (692,56). The one asked
    /// for is the SECOND element; the old matcher raised the first.
    func testSameOriginResolvesToTheRequestedWindowBySize() {
        let result = resolve(origin: CGPoint(x: 692, y: 56), size: CGSize(width: 1400, height: 900),
                             title: "Docs",
                             [C(origin: CGPoint(x: 692, y: 56), size: CGSize(width: 800, height: 600), title: "Docs"),
                              C(origin: CGPoint(x: 692, y: 56), size: CGSize(width: 1400, height: 900), title: "Docs")])
        XCTAssertEqual(result, .unique(1))
    }

    func testSameOriginAndSizeResolvesByTitle() {
        let size = CGSize(width: 1200, height: 800)
        let result = resolve(origin: CGPoint(x: 692, y: 56), size: size, title: "Inbox",
                             [C(origin: CGPoint(x: 692, y: 56), size: size, title: "Calendar"),
                              C(origin: CGPoint(x: 693, y: 57), size: size, title: "Inbox")])
        XCTAssertEqual(result, .unique(1))
    }

    func testIdenticalWindowsStayAmbiguousInsteadOfGuessing() {
        let size = CGSize(width: 1200, height: 800)
        let twin = C(origin: CGPoint(x: 10, y: 10), size: size, title: "zsh")
        XCTAssertEqual(resolve(origin: CGPoint(x: 10, y: 10), size: size, title: "zsh", [twin, twin]),
                       .ambiguous([0, 1]))
    }

    /// Moved since the 2.0s poll: position misses, title + size still identify it.
    func testMovedWindowFallsBackToTitleAndSize() {
        let size = CGSize(width: 900, height: 700)
        let result = resolve(origin: CGPoint(x: 0, y: 0), size: size, title: "claude — repo",
                             [C(origin: CGPoint(x: 400, y: 300), size: CGSize(width: 500, height: 500), title: "other"),
                              C(origin: CGPoint(x: 850, y: 120), size: size, title: "claude — repo")])
        XCTAssertEqual(result, .unique(1))
    }

    func testWindowWithNoReadablePositionIsFoundByTitleAndSize() {
        let size = CGSize(width: 900, height: 700)
        let result = resolve(origin: CGPoint(x: 50, y: 50), size: size, title: "Finder",
                             [C(origin: nil, size: size, title: "Finder")])
        XCTAssertEqual(result, .unique(0))
    }

    func testTitleAloneIsNotEnoughWhenSizeDiffers() {
        let result = resolve(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 900, height: 700), title: "zsh",
                             [C(origin: CGPoint(x: 500, y: 500), size: CGSize(width: 300, height: 200), title: "zsh")])
        XCTAssertEqual(result, .none)
    }

    func testEmptyTitleNeverMatchesByIdentity() {
        let size = CGSize(width: 900, height: 700)
        let result = resolve(origin: CGPoint(x: 0, y: 0), size: size, title: "",
                             [C(origin: CGPoint(x: 500, y: 500), size: size, title: "")])
        XCTAssertEqual(result, .none)
    }

    func testTwoMovedWindowsWithSameTitleAndSizeAreAmbiguous() {
        let size = CGSize(width: 900, height: 700)
        let twin = C(origin: CGPoint(x: 800, y: 800), size: size, title: "zsh")
        XCTAssertEqual(resolve(origin: CGPoint(x: 0, y: 0), size: size, title: "zsh", [twin, twin]),
                       .ambiguous([0, 1]))
    }

    /// A title that matches NO same-origin candidate (stale, or the app-name
    /// fallback CG uses without Screen Recording) must not turn a real tie into
    /// "none": the tie is reported as ambiguous, so it is logged as a tie.
    func testATitleMatchingNoSameOriginCandidateStaysAmbiguous() {
        let size = CGSize(width: 800, height: 600)
        let result = resolve(origin: CGPoint(x: 5, y: 5), size: size, title: "iTerm2",
                             [C(origin: CGPoint(x: 5, y: 5), size: size, title: "one"),
                              C(origin: CGPoint(x: 5, y: 5), size: size, title: "two")])
        XCTAssertEqual(result, .ambiguous([0, 1]))
    }
}
