import XCTest
@testable import Quip

/// Locks the predicate that decides when an injection failure should refresh
/// the iTerm2 session-id map and retry once before failing. Prefers the
/// structured `InjectionError.sessionNotFound` (#4); falls back to a string
/// match for unclassified errors. Triggered by the AppleScript "Quip: iTerm2
/// session ... not found" path.
final class SendTextSelfHealTests: XCTestCase {

    private func fail(_ message: String,
                      kind: KeystrokeInjector.InjectionError? = nil) -> KeystrokeInjector.InjectionResult {
        KeystrokeInjector.InjectionResult(success: false, error: message, kind: kind)
    }

    private func ok() -> KeystrokeInjector.InjectionResult {
        KeystrokeInjector.InjectionResult(success: true, error: nil)
    }

    // MARK: - shouldSelfHealStaleSession

    func test_structuredSessionNotFound_triggersSelfHeal() {
        let r = fail("anything", kind: .sessionNotFound)
        XCTAssertTrue(QuipMacApp.shouldSelfHealStaleSession(result: r, terminalApp: .iterm2))
    }

    func test_stringFallback_notFound_triggersSelfHeal() {
        // Unclassified failure carrying a "not found" string still self-heals.
        let r = fail("Quip: iTerm2 session ABC123 not found")
        XCTAssertTrue(QuipMacApp.shouldSelfHealStaleSession(result: r, terminalApp: .iterm2))
    }

    func test_success_doesNotTrigger() {
        XCTAssertFalse(QuipMacApp.shouldSelfHealStaleSession(result: ok(), terminalApp: .iterm2))
    }

    func test_terminalApp_doesNotTriggerEvenWithNotFound() {
        let r = fail("Quip: session not found", kind: .sessionNotFound)
        XCTAssertFalse(QuipMacApp.shouldSelfHealStaleSession(result: r, terminalApp: .terminal))
    }

    func test_unrelatedError_doesNotTrigger() {
        let r = fail("permission denied", kind: .tccDenied)
        XCTAssertFalse(QuipMacApp.shouldSelfHealStaleSession(result: r, terminalApp: .iterm2))
    }

    // MARK: - classifyAppleScriptError (#4)

    func test_classify_sessionNotFound() {
        XCTAssertEqual(KeystrokeInjector.classifyAppleScriptError("Quip: iTerm2 session ABC not found"),
                       .sessionNotFound)
    }

    func test_classify_tccDenied() {
        XCTAssertEqual(KeystrokeInjector.classifyAppleScriptError("Not authorized to send Apple events"),
                       .tccDenied)
    }

    func test_classify_unknown_carriesMessage() {
        if case .unknown(let msg) = KeystrokeInjector.classifyAppleScriptError("script timed out") {
            XCTAssertEqual(msg, "script timed out")
        } else {
            XCTFail("expected .unknown(...)")
        }
    }
}
