import XCTest
@testable import Quip

/// Locks the predicate that decides when `send_text` should refresh the
/// iTerm2 session-id map and retry once before failing. Triggered by the
/// AppleScript "Quip: iTerm2 session ... not found" error path.
final class SendTextSelfHealTests: XCTestCase {

    func test_iterm2_sessionNotFound_triggersSelfHeal() {
        XCTAssertTrue(QuipMacApp.shouldSelfHealStaleSession(
            injectionError: "Quip: iTerm2 session ABC123 not found",
            terminalApp: .iterm2))
    }

    func test_iterm2_caseInsensitive() {
        XCTAssertTrue(QuipMacApp.shouldSelfHealStaleSession(
            injectionError: "the SESSION was NOT FOUND",
            terminalApp: .iterm2))
    }

    func test_nilError_doesNotTrigger() {
        XCTAssertFalse(QuipMacApp.shouldSelfHealStaleSession(
            injectionError: nil, terminalApp: .iterm2))
    }

    func test_terminalApp_doesNotTriggerEvenWithNotFound() {
        // Terminal.app has no per-session id concept; the heal path is iTerm-only.
        XCTAssertFalse(QuipMacApp.shouldSelfHealStaleSession(
            injectionError: "Quip: session not found", terminalApp: .terminal))
    }

    func test_unrelatedError_doesNotTrigger() {
        XCTAssertFalse(QuipMacApp.shouldSelfHealStaleSession(
            injectionError: "permission denied", terminalApp: .iterm2))
    }
}
