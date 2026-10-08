import XCTest
@testable import Quip

/// Both Arrange buttons report from `ArrangeOutcome`. The menu-bar one used to
/// return silently on a missing display and ignore a refused move, so it could
/// do nothing with no word as to why.
final class ArrangeOutcomeTests: XCTestCase {

    func test_noWindows_doesNotAttemptTheMove() {
        var calls = 0
        let outcome = ArrangeOutcome.evaluate(enabledCount: 0, hasDisplay: true) {
            calls += 1
            return true
        }
        XCTAssertEqual(outcome, .noWindows)
        XCTAssertEqual(calls, 0)
    }

    func test_noDisplay_doesNotAttemptTheMove() {
        var calls = 0
        let outcome = ArrangeOutcome.evaluate(enabledCount: 3, hasDisplay: false) {
            calls += 1
            return true
        }
        XCTAssertEqual(outcome, .noDisplay)
        XCTAssertEqual(calls, 0)
    }

    func test_refusedMove_isAccessibilityDenied() {
        var calls = 0
        let outcome = ArrangeOutcome.evaluate(enabledCount: 2, hasDisplay: true) {
            calls += 1
            return false
        }
        XCTAssertEqual(outcome, .accessibilityDenied)
        XCTAssertEqual(calls, 1)
    }

    func test_acceptedMove_isArranged() {
        var calls = 0
        let outcome = ArrangeOutcome.evaluate(enabledCount: 2, hasDisplay: true) {
            calls += 1
            return true
        }
        XCTAssertEqual(outcome, .arranged)
        XCTAssertEqual(calls, 1)
    }

    func test_message_isNilOnlyWhenArranged() {
        XCTAssertNil(ArrangeOutcome.arranged.message)
        for outcome in [ArrangeOutcome.noWindows, .noDisplay, .accessibilityDenied] {
            XCTAssertNotNil(outcome.message, "\(outcome) must tell the user why nothing moved")
        }
    }

    func test_accessibilityMessage_pointsAtTheSettingsPane() {
        XCTAssertEqual(
            ArrangeOutcome.accessibilityDenied.message,
            "Quip needs Accessibility access to move windows. Grant it in System Settings → Privacy & Security → Accessibility."
        )
    }
}
