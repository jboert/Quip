import XCTest
@testable import Quip

/// The frontmost-window match was extracted from `currentFrontmostManagedWindowId`
/// so the two blocking Accessibility round-trips could move off the main thread.
/// These pin the matching behavior that extraction had to preserve.
final class FrontmostMatchTests: XCTestCase {

    private func candidate(_ id: String, _ x: CGFloat, _ y: CGFloat) -> QuipMacApp.FrontmostCandidate {
        QuipMacApp.FrontmostCandidate(id: id, origin: CGPoint(x: x, y: y))
    }

    func test_exactOrigin_matches() {
        let result = QuipMacApp.matchFrontmost(
            origin: CGPoint(x: 100, y: 200),
            candidates: [candidate("a", 100, 200), candidate("b", 900, 900)]
        )
        XCTAssertEqual(result, "a")
    }

    func test_nearestCandidateWins() {
        let result = QuipMacApp.matchFrontmost(
            origin: CGPoint(x: 100, y: 200),
            candidates: [candidate("far", 130, 230), candidate("near", 105, 205)]
        )
        XCTAssertEqual(result, "near")
    }

    /// 50pt tolerance: 30/40 is exactly 50pt away (distSq 2500) and still counts.
    func test_originAtToleranceBoundary_matches() {
        let result = QuipMacApp.matchFrontmost(
            origin: CGPoint(x: 100, y: 200),
            candidates: [candidate("a", 130, 240)]
        )
        XCTAssertEqual(result, "a")
    }

    /// Past 50pt we'd be guessing — send nil rather than mis-route input.
    func test_originBeyondTolerance_returnsNil() {
        let result = QuipMacApp.matchFrontmost(
            origin: CGPoint(x: 100, y: 200),
            candidates: [candidate("a", 160, 200)]
        )
        XCTAssertNil(result)
    }

    /// A failed AX query yields no origin; the phone keeps its last target.
    func test_nilOrigin_returnsNil() {
        XCTAssertNil(QuipMacApp.matchFrontmost(origin: nil, candidates: [candidate("a", 0, 0)]))
    }

    /// Frontmost app is untracked (Finder, Safari, …).
    func test_noCandidates_returnsNil() {
        XCTAssertNil(QuipMacApp.matchFrontmost(origin: CGPoint(x: 0, y: 0), candidates: []))
    }
}
