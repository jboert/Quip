import XCTest
@testable import Quip

/// Locks `TranscriptCorrector` (US-005) so the curated Quip-vocabulary
/// mishearing remaps keep firing AND ordinary prose keeps passing through
/// untouched. This is the only correction the remote Whisper path gets (it has
/// no `contextualStrings` biasing), so a regression here silently re-mangles
/// every connected-path PTT.
final class TranscriptCorrectorTests: XCTestCase {

    private let corrector = TranscriptCorrector.shared

    // MARK: Captured manglings -> canonical terms

    func test_tailScale_mapsToTailscale() {
        XCTAssertEqual(corrector.correct("tail scale"), "Tailscale")
    }

    func test_match_isCaseInsensitive() {
        XCTAssertEqual(corrector.correct("Tail Scale"), "Tailscale")
    }

    func test_monoType_mapsToMonospace() {
        XCTAssertEqual(corrector.correct("mono type"), "monospace")
        XCTAssertEqual(corrector.correct("monotype"), "monospace")
    }

    func test_webSocket_mapsToWebSocket() {
        XCTAssertEqual(corrector.correct("web socket"), "WebSocket")
    }

    func test_coDex_mapsToCodex() {
        XCTAssertEqual(corrector.correct("co-dex"), "Codex")
        XCTAssertEqual(corrector.correct("co dex"), "Codex")
    }

    func test_xCode_mapsToXcode() {
        XCTAssertEqual(corrector.correct("x code"), "Xcode")
    }

    func test_longerPhraseWins_xCodeGen_mapsToXcodegen() {
        // "x code gen" must resolve to Xcodegen, not "Xcode gen".
        XCTAssertEqual(corrector.correct("x code gen"), "Xcodegen")
    }

    func test_finTech_mapsToFintech() {
        XCTAssertEqual(corrector.correct("fin tech"), "Fintech")
        XCTAssertEqual(corrector.correct("finn tech"), "Fintech")
    }

    func test_whisperers_mapsToWhisper() {
        XCTAssertEqual(corrector.correct("whisperers"), "Whisper")
    }

    // MARK: Surrounding text + whitespace preservation

    func test_phraseEmbeddedInSentence_surroundingTextPreserved() {
        XCTAssertEqual(corrector.correct("connect over tail scale please"),
                       "connect over Tailscale please")
        XCTAssertEqual(corrector.correct("use a mono type font"),
                       "use a monospace font")
    }

    func test_leadingAndTrailingWhitespacePreserved() {
        // The send pipeline relies on surrounding whitespace — only the matched
        // span may change.
        XCTAssertEqual(corrector.correct(" tail scale "), " Tailscale ")
        XCTAssertEqual(corrector.correct("open x code\n"), "open Xcode\n")
    }

    // MARK: Whole-word only

    func test_substringInsideLargerWord_notRemapped() {
        XCTAssertEqual(corrector.correct("xcoder"), "xcoder")
        XCTAssertEqual(corrector.correct("retail scale model"), "retail scale model")
    }

    func test_newTermNearMisses_notRemapped() {
        // Singular "whisperer" and the lone words "fin"/"tech" must pass through —
        // only the exact mishearings ("whisperers", "fin tech") may be remapped.
        XCTAssertEqual(corrector.correct("a whisperer in the dark"), "a whisperer in the dark")
        XCTAssertEqual(corrector.correct("the fin of the fish"), "the fin of the fish")
        XCTAssertEqual(corrector.correct("low tech"), "low tech")
    }

    // MARK: Non-Quip prose passes through untouched

    func test_ordinaryProse_untouched() {
        let prose = "the quick brown fox jumps over the lazy dog"
        XCTAssertEqual(corrector.correct(prose), prose)
    }

    func test_emptyAndWhitespaceOnly_untouched() {
        XCTAssertEqual(corrector.correct(""), "")
        XCTAssertEqual(corrector.correct("   "), "   ")
    }
}
