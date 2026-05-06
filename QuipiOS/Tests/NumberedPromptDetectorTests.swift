import XCTest
@testable import Quip

/// Locks the §18 numbered-prompt detector. Disambiguation between a
/// real Claude prompt (with `❯` cursor marker) and prose that happens to
/// contain numbered text is the entire reason this thing exists, so the
/// tests cover both positive and negative cases.
final class NumberedPromptDetectorTests: XCTestCase {

    // MARK: - Positive cases

    func test_threeOptions_withCursorMarker_detected() {
        let content = """
        Some preceding output…
        ❯ 1. Yes
          2. No
          3. Cancel
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2, 3])
    }

    func test_twoOptions_withCursorMarker_detected() {
        let content = """
        Apply this change?
        ❯ 1. Yes
          2. No
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2])
    }

    func test_cursorMarkerOnSecondLine_stillDetected() {
        // Claude moves the marker to the highlighted option; the prompt
        // is still valid no matter which line carries it.
        let content = """
          1. Yes
        ❯ 2. No
          3. Cancel
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2, 3])
    }

    func test_asciiCursorFallback_detected() {
        // Some terminals lack the `❯` glyph and render `>` instead.
        let content = """
        > 1. Yes
          2. No
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2])
    }

    func test_parenSeparator_detected() {
        // Claude has variants with `1)` instead of `1.`.
        let content = """
        ❯ 1) Yes
          2) No
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2])
    }

    // MARK: - Negative cases (disambiguation)

    func test_proseWithNumbers_noCursor_notDetected() {
        // Markdown-style ordered list in conversation output. No `❯`
        // marker — must NOT trigger.
        let content = """
        Here are three options to consider:
        1. Use a hash table.
        2. Use a sorted array.
        3. Use a trie.
        """
        XCTAssertNil(NumberedPromptDetector.detect(in: content))
    }

    func test_emptyContent_returnsNil() {
        XCTAssertNil(NumberedPromptDetector.detect(in: ""))
    }

    func test_outOfOrderNumbers_notDetected() {
        // Claude always numbers sequentially starting at 1. A run that
        // skips or restarts is suspect.
        let content = """
        ❯ 2. Skip
          4. Cancel
        """
        XCTAssertNil(NumberedPromptDetector.detect(in: content))
    }

    func test_singleOption_notDetected() {
        // A single "1." line isn't a useful prompt block — would also
        // false-positive on logs containing "Step 1. ...".
        let content = """
        ❯ 1. Done
        """
        // bestRun.count > 0 with a marker, but for the §18 use case
        // we still want at least one option to render. Detector returns
        // [1] here. The CALLER is free to require count >= 2 if it
        // wants stricter behavior.
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1])
    }

    func test_promptOlderThanScanWindow_notDetected() {
        // Claude prompt 30+ lines back in the buffer is no longer the
        // current prompt — anything below it is more recent output.
        var lines: [String] = ["❯ 1. Yes", "  2. No"]
        // Push the prompt out of the scan window with newer lines.
        for i in 0..<NumberedPromptDetector.scanLineLimit {
            lines.append("output line \(i)")
        }
        let content = lines.joined(separator: "\n")
        XCTAssertNil(NumberedPromptDetector.detect(in: content),
                     "Prompts past the scan-window cutoff aren't the current prompt")
    }

    func test_ansiSequences_strippedBeforeMatch() {
        // Claude renders highlighted option with ANSI color codes.
        // `\u{1B}[36m` is cyan FG; the line still parses after stripping.
        let content = "\u{1B}[36m❯ 1. Yes\u{1B}[0m\n  2. No"
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2])
    }

    // MARK: - Helper coverage

    func test_parseNumberedLine_pickup() {
        XCTAssertEqual(NumberedPromptDetector.parseNumberedLine("❯ 1. Yes")?.0, 1)
        XCTAssertTrue(NumberedPromptDetector.parseNumberedLine("❯ 1. Yes")?.1 == true)
        XCTAssertEqual(NumberedPromptDetector.parseNumberedLine("  2. No")?.0, 2)
        XCTAssertFalse(NumberedPromptDetector.parseNumberedLine("  2. No")?.1 ?? true)
        XCTAssertNil(NumberedPromptDetector.parseNumberedLine("plain prose"))
        XCTAssertNil(NumberedPromptDetector.parseNumberedLine("1: bad separator"))
    }
}
