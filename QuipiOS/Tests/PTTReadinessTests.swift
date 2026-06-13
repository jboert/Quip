import XCTest
@testable import Quip

/// Locks `PTTReadiness.classify(...)` — the mic-badge readiness shown next to
/// the connection dot. Regression guard for the incomplete Grok rollout
/// (`420272e` added Grok routing + the `.grok` short-hint but left `classify()`
/// hardcoded to `.codex`, so Grok panes showed "Selected window isn't Codex"
/// even though PTT routes Grok identically to Codex). Voice-ready means the
/// selected window is a paste-path AI CLI: Codex OR Grok.
final class PTTReadinessTests: XCTestCase {

    private func classify(_ cli: CLIKind?) -> PTTReadiness {
        PTTReadiness.classify(isAuthenticated: true, isAuthorized: true, selectedCLI: cli)
    }

    func test_codex_isReady() {
        XCTAssertEqual(classify(.codex), .ready)
    }

    func test_grok_isReady() {
        // The bug: Grok routes via pasteText exactly like Codex on the Mac,
        // but the badge claimed the window "isn't Codex". Grok must be ready.
        XCTAssertEqual(classify(.grok), .ready,
                       "Grok is a paste-path voice target — must read as ready, not .wrongCLI")
    }

    func test_shell_isWrongCLI() {
        XCTAssertEqual(classify(.shell), .wrongCLI)
    }

    func test_claude_isWrongCLI() {
        // Deliberate: PTT-into-Claude was never the intended green-light flow
        // (Claude takes the sendText path). Left as-is to keep this fix scoped
        // to the reported Codex/Grok symptom; revisit if voice-to-Claude ships.
        XCTAssertEqual(classify(.claude), .wrongCLI)
    }

    func test_nil_isWrongCLI() {
        XCTAssertEqual(classify(nil), .wrongCLI)
    }

    func test_micDenied_outranks_cli() {
        XCTAssertEqual(
            PTTReadiness.classify(isAuthenticated: true, isAuthorized: false, selectedCLI: .codex),
            .micDenied,
            "Mic permission is the most actionable signal — it must win over CLI readiness")
    }

    func test_offline_whenNotAuthenticated() {
        XCTAssertEqual(
            PTTReadiness.classify(isAuthenticated: false, isAuthorized: true, selectedCLI: .grok),
            .offline)
    }
}
