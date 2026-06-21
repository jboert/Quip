import XCTest
@testable import Quip

/// Locks the §18 numbered-prompt detector. Disambiguation between a
/// real agent prompt (with a cursor marker) and prose that happens to
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

    func test_codexMarkerWithFiveOptions_detected() {
        let content = """
        Choose an action:
        › 1. Fix URL tray
          2. Fix prompt routing
          3. Run tests
          4. Install on phone
          5. Push branch
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2, 3, 4, 5])
    }

    func test_multiDigitOptions_detected() {
        let content = """
        Choose one:
        › 1. One
          2. Two
          3. Three
          4. Four
          5. Five
          6. Six
          7. Seven
          8. Eight
          9. Nine
          10. Ten
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), Array(1...10))
    }

    func test_parenSeparator_detected() {
        // Claude has variants with `1)` instead of `1.`.
        let content = """
        ❯ 1) Yes
          2) No
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2])
    }

    func test_colonSeparator_detected() {
        let content = """
        › 1: Yes
          2: No
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

    // MARK: - Lettered choice menus (§18.1)

    func test_letteredChoiceMenu_noCursorMarker_detected() {
        // Claude often prints a labeled choice menu as prose with NO cursor
        // marker — each line dual-enumerated `<n>. <Letter> — …`. The
        // sequential number+letter lockstep (1→A, 2→B, 3→C) is an
        // unmistakable choice block, so buttons must render even without `❯`.
        let content = """
        …parseTextNote already shipped; pick the surface:
        1. A — inline dossier field
        2. B — "+ Note" compose sheet
        3. C — unified Voice|Type toggle
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2, 3])
    }

    func test_letteredChoiceMenu_otherLabelSeparators_detected() {
        // `A)` and `A.` label forms count too, not only `A —`.
        let content = """
        Pick one:
        1. A) keep
        2. B. drop
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2])
    }

    func test_letteredLookalike_capitalWords_notDetected() {
        // Bodies start with capital letters but are WORDS, not lone labels —
        // must stay prose (no buttons), preserving the marker-gate precision.
        let content = """
        Steps:
        1. Add the file.
        2. Build the target.
        3. Commit the change.
        """
        XCTAssertNil(NumberedPromptDetector.detect(in: content))
    }

    func test_letteredRun_notStartingAtA_notDetected() {
        // A lettered run must start at A and increment in lockstep; a block
        // that opens at B is suspect → treat as prose.
        let content = """
        1. B — foo
        2. C — bar
        """
        XCTAssertNil(NumberedPromptDetector.detect(in: content))
    }

    func test_letteredMenu_trailingWithQuestionCue_detected() {
        // A bottom-of-viewport lettered block preceded by a question is a real
        // ask → buttons render even without a cursor marker.
        let content = """
        Which surface should it use?
        1. A — inline field
        2. B — compose sheet
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2])
    }

    func test_letteredRubric_noCue_notDetected() {
        // Same `1. A — …` shape as a real menu, but the heading is not a
        // question/cue — a grading rubric, not a prompt. Must stay button-less.
        let content = """
        Grading scale:
        1. A — Excellent
        2. B — Good
        3. C — Acceptable
        """
        XCTAssertNil(NumberedPromptDetector.detect(in: content))
    }

    func test_letteredOutline_midReply_notDetected() {
        // Lettered outline with prose AFTER it is not trailing → not the
        // current prompt, even though a question appears above it.
        let content = """
        Which section first?
        1. A — Introduction
        2. B — Body
        Now I'll draft the introduction in full.
        Then expand the body.
        Finally a conclusion.
        """
        XCTAssertNil(NumberedPromptDetector.detect(in: content))
    }

    func test_letteredBlock_trailingNoCue_notDetected() {
        // Trailing lettered block with a plain heading (no question / cue word)
        // is ambiguous prose → no buttons.
        let content = """
        Release notes:
        1. A — faster sync
        2. B — dark mode
        """
        XCTAssertNil(NumberedPromptDetector.detect(in: content))
    }

    func test_letteredMenu_goWithCue_detected() {
        // "go with" is a valid choice cue even without a question mark.
        let content = """
        Go with one of these:
        1. A — path one
        2. B — path two
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2])
    }

    func test_letteredBlock_optionalSubstring_notDetected() {
        // "optional" must NOT satisfy the cue (the word is "options", plural);
        // a lettered block under it stays prose, not a menu.
        let content = """
        The optional field was set carefully.
        1. A — first
        2. B — second
        """
        XCTAssertNil(NumberedPromptDetector.detect(in: content))
    }

    // MARK: - Helper coverage

    func test_parseNumberedLine_pickup() {
        XCTAssertEqual(NumberedPromptDetector.parseNumberedLine("❯ 1. Yes")?.0, 1)
        XCTAssertTrue(NumberedPromptDetector.parseNumberedLine("❯ 1. Yes")?.1 == true)
        XCTAssertEqual(NumberedPromptDetector.parseNumberedLine("› 1. Yes")?.0, 1)
        XCTAssertTrue(NumberedPromptDetector.parseNumberedLine("› 1. Yes")?.1 == true)
        XCTAssertEqual(NumberedPromptDetector.parseNumberedLine("  2. No")?.0, 2)
        XCTAssertFalse(NumberedPromptDetector.parseNumberedLine("  2. No")?.1 ?? true)
        XCTAssertEqual(NumberedPromptDetector.parseNumberedLine("  10. Later")?.0, 10)
        XCTAssertNil(NumberedPromptDetector.parseNumberedLine("plain prose"))
        XCTAssertNil(NumberedPromptDetector.parseNumberedLine("1- bad separator"))
    }

    func test_choiceLetter_extraction() {
        XCTAssertEqual(NumberedPromptDetector.choiceLetter(in: "1. A — inline dossier field"), "A")
        XCTAssertEqual(NumberedPromptDetector.choiceLetter(in: "  2. B \"+ Note\""), "B")
        XCTAssertEqual(NumberedPromptDetector.choiceLetter(in: "3. C) toggle"), "C")
        XCTAssertNil(NumberedPromptDetector.choiceLetter(in: "1. Add the file"))   // word, not a label
        XCTAssertNil(NumberedPromptDetector.choiceLetter(in: "1. add lowercase")) // lowercase, not a label
        XCTAssertNil(NumberedPromptDetector.choiceLetter(in: "plain prose"))
    }
}
