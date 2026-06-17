import XCTest
@testable import Quip

/// Pins the pure prompt/token builder that seeds the WhisperKit decode with
/// Quip vocabulary (US-003). The builder is dependency-injected with the
/// tokenizer's `encode`, so these run without a loaded model — the live decode
/// wiring in `WhisperKitTranscriber` is the user's on-device pass.
final class QuipDictationVocabularyTests: XCTestCase {

    func testPromptTextIsCommaJoinedVocabulary() {
        let text = QuipDictationVocabulary.promptText
        // High-signal domain terms must be present so the decoder sees them.
        XCTAssertTrue(text.contains("Tailscale"))
        XCTAssertTrue(text.contains("monospace"))
        XCTAssertTrue(text.contains("Codex"))
        XCTAssertTrue(text.contains("WebSocket"))
        XCTAssertTrue(text.contains(", "), "terms should be comma-joined")
    }

    func testPromptTokensPrependsLeadingSpaceAndUsesFullVocabulary() {
        var seen: String?
        _ = QuipDictationVocabulary.promptTokens(
            encode: { text in seen = text; return [1] },
            specialTokenBegin: 50_000)
        XCTAssertEqual(seen?.first, " ", "WhisperKit recipe prepends a leading space")
        XCTAssertEqual(seen, " " + QuipDictationVocabulary.promptText)
    }

    func testPromptTokensFiltersSpecialTokens() {
        // 99 and 100 are >= specialTokenBegin and must be dropped; only real
        // vocabulary tokens (< begin) survive into the prefill.
        let tokens = QuipDictationVocabulary.promptTokens(
            encode: { _ in [10, 99, 20, 100, 30] },
            specialTokenBegin: 99)
        XCTAssertEqual(tokens, [10, 20, 30])
    }

    func testPromptTokensReturnsNilWhenEncodeYieldsNothingUsable() {
        // A degraded tokenizer (empty encode) must fall back to nil ⇒ unbiased
        // decode, never an empty-array prompt.
        XCTAssertNil(QuipDictationVocabulary.promptTokens(
            encode: { _ in [] }, specialTokenBegin: 50_000))
        // Everything filtered out as special ⇒ also nil.
        XCTAssertNil(QuipDictationVocabulary.promptTokens(
            encode: { _ in [99, 100] }, specialTokenBegin: 50))
    }
}
