import XCTest
@testable import Quip

/// Regression coverage: WhisperKit emits placeholder tokens like
/// `[BLANK_AUDIO]` and `(silence)` for non-speech audio, which used to
/// be typed verbatim into the user's terminal. WhisperOutputCleaner strips
/// these before sending; these tests pin the contract so a future
/// "let's keep the brackets" refactor can't silently regress dictation
/// quality.
final class WhisperOutputCleanerTests: XCTestCase {

    func testStripsBracketedBlankAudio() {
        XCTAssertEqual(WhisperOutputCleaner.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperOutputCleaner.clean("[blank_audio]"), "")
        XCTAssertEqual(WhisperOutputCleaner.clean("[BLANK AUDIO]"), "")
        XCTAssertEqual(WhisperOutputCleaner.clean("[ BLANK AUDIO ]"), "")
        XCTAssertEqual(WhisperOutputCleaner.clean("[Blank-Audio]"), "")
    }

    func testStripsParenthesizedSilence() {
        XCTAssertEqual(WhisperOutputCleaner.clean("(silence)"), "")
        XCTAssertEqual(WhisperOutputCleaner.clean("(SILENCE)"), "")
        XCTAssertEqual(WhisperOutputCleaner.clean("( silence )"), "")
    }

    func testStripsKnownTokenFamily() {
        let tokens = [
            "[NO_SPEECH]", "(no_speech)", "[NO SPEECH]",
            "[MUSIC]", "(music)",
            "[INAUDIBLE]", "(inaudible)",
            "[APPLAUSE]", "(applause)",
            "[LAUGHTER]", "(laughter)",
            "[CROSSTALK]",
            "[BACKGROUND_NOISE]", "(background noise)",
            "[FOREIGN_LANGUAGE]", "(foreign language)",
            "[INDISTINCT]",
        ]
        for t in tokens {
            XCTAssertEqual(WhisperOutputCleaner.clean(t), "",
                           "expected token \(t) to be stripped")
        }
    }

    func testPreservesRealSpeechAroundTokens() {
        XCTAssertEqual(
            WhisperOutputCleaner.clean("Hello [BLANK_AUDIO] world"),
            "Hello world"
        )
        XCTAssertEqual(
            WhisperOutputCleaner.clean("Open the file (silence) and save it"),
            "Open the file and save it"
        )
        XCTAssertEqual(
            WhisperOutputCleaner.clean("[BLANK_AUDIO] start"),
            "start"
        )
        XCTAssertEqual(
            WhisperOutputCleaner.clean("end [silence]"),
            "end"
        )
    }

    func testDoesNotStripUserParens() {
        // User dictating real prose with parentheses — must NOT be touched.
        XCTAssertEqual(
            WhisperOutputCleaner.clean("call foo(bar) please"),
            "call foo(bar) please"
        )
        XCTAssertEqual(
            WhisperOutputCleaner.clean("do this (and that) too"),
            "do this (and that) too"
        )
        XCTAssertEqual(
            WhisperOutputCleaner.clean("array[0]"),
            "array[0]"
        )
    }

    func testCollapsesWhitespaceFromStrips() {
        XCTAssertEqual(
            WhisperOutputCleaner.clean("first  [BLANK_AUDIO]  second"),
            "first second"
        )
    }

    func testEmptyAndAllWhitespacePassesThrough() {
        XCTAssertEqual(WhisperOutputCleaner.clean(""), "")
        XCTAssertEqual(WhisperOutputCleaner.clean("   "), "")
        XCTAssertEqual(WhisperOutputCleaner.clean("\n\t"), "")
    }

    func testMultipleConsecutiveTokens() {
        XCTAssertEqual(
            WhisperOutputCleaner.clean("[BLANK_AUDIO][SILENCE](music)"),
            ""
        )
        XCTAssertEqual(
            WhisperOutputCleaner.clean("[BLANK_AUDIO] [BLANK_AUDIO] hello"),
            "hello"
        )
    }
}
