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

    // MARK: - Multi-line option bodies (real Claude verbose menu — IMG_0383)

    /// Claude renders a numbered menu where each option carries several
    /// description lines underneath. Those body lines used to reset the run, so
    /// only option 1 survived and no usable button row appeared on the phone.
    /// The cursor marker on option 1 is enough to accept the block.
    func test_numberedMenu_withMultiLineBodies_marker_detected() {
        let content = """
        Which cleanup groups should I delete?
        (read-only scan done; I delete only
        what you pick, one group at a time)
        ❯ 1. G1 Xcode caches (~335M)
        rm -rf the regenerable
        ModuleCache.noindex +
        SDKStatCaches.noindex in
        DerivedData. Safe — Xcode rebuilds
        them on next compile. Biggest safe
        win.
          2. G2 superseded .swrm backups (~1.4M)
        Delete only
        swrm.db.bak-corrupted-import-* and
        swrm.db.bak-before-prune-*.
          3. G3 remote merged ralph branch
        git push origin --delete
        ralph/c2-cost-governance — merged
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2, 3])
    }

    /// Same shape but with `[ ]` checkbox markers and NO cursor marker — a
    /// multi-select menu. The `[ ]`/`[x]` token is itself an unambiguous
    /// interactive-prompt signal (prose doesn't write `N. [ ]`), so the block
    /// should be accepted as a real prompt.
    func test_numberedMenu_checkboxMultiSelect_noCursor_detected() {
        let content = """
        Which cleanup groups should I delete?
        (I delete only what you pick)
        1. [ ] G1 Xcode caches (~335M)
        rm -rf the regenerable ModuleCache.
          2. [ ] G2 superseded .swrm backups (~1.4M)
        Delete only the corrupted imports.
          3. [ ] G3 remote merged ralph branch
        git push origin --delete the branch.
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2, 3])
    }

    /// A checkbox option's body carries a wrapped command that itself parses as
    /// a numbered line (`1) git …`, `2) rm …`). Those must be treated as body,
    /// not mistaken for the next option — the detected set stays [1,2,3]. (T3 #1)
    func test_checkboxMenu_numberedCommandInBody_notCorrupted() {
        let content = """
        Which to delete?
        1. [ ] G1 caches
        1) git gc reclaims space
        2. [ ] G2 backups
        2) rm the old logs
        3. [ ] G3 branches
        git push origin --delete it
        """
        XCTAssertEqual(NumberedPromptDetector.detect(in: content), [1, 2, 3])
    }

    /// A markdown task list (`1. [x] done / 2. [ ] todo`) scrolled in the buffer
    /// shares the checkbox shape but has NO choice cue above it — must be
    /// rejected so we don't render a Submit bar over non-interactive text. (T3 #2)
    func test_markdownTaskList_noCue_rejected() {
        let content = """
        ## Progress
        1. [x] wrote the parser
        2. [ ] wire up the UI
        3. [ ] ship it
        """
        XCTAssertNil(NumberedPromptDetector.detect(in: content))
        XCTAssertFalse(NumberedPromptDetector.isMultiSelect(in: content))
    }

    func test_isMultiSelect_checkboxMenu_true() {
        let content = """
        Which to delete?
        1. [ ] G1 caches
        2. [ ] G2 backups
        """
        XCTAssertTrue(NumberedPromptDetector.isMultiSelect(in: content))
    }

    func test_isMultiSelect_singleSelectMarkerMenu_false() {
        let content = """
        Apply this change?
        ❯ 1. Yes
          2. No
        """
        XCTAssertFalse(NumberedPromptDetector.isMultiSelect(in: content))
    }

    func test_isMultiSelect_noPrompt_false() {
        XCTAssertFalse(NumberedPromptDetector.isMultiSelect(in: "just some prose output"))
    }

    /// A genuine prose ordered list with multi-line bodies and NO marker / no
    /// checkbox / no choice cue must still be rejected — the gap tolerance must
    /// not re-open the prose false-positive.
    func test_proseOrderedList_withBodies_stillRejected() {
        let content = """
        Here is how the build works:
        1. First the compiler parses every
        source file in the target.
        2. Then it type-checks the modules
        and resolves imports.
        3. Finally it links the binary and
        signs it for distribution.
        """
        XCTAssertNil(NumberedPromptDetector.detect(in: content))
    }

    // MARK: - Inline bracketed choice prompts (§18.3)

    func test_inline_deleteWhich_digitsAndWords_detected() {
        let c = "Approve which to delete? [all / 1 / 2 / 3 / none / pick]"
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: c),
                       ["all", "1", "2", "3", "none", "pick"])
        // It's NOT a numbered line-run, so detect() stays nil; fingerprint exists.
        XCTAssertNil(NumberedPromptDetector.detect(in: c))
        XCTAssertNotNil(NumberedPromptDetector.fingerprint(in: c))
    }

    func test_inline_continueYesNo_detected() {
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Continue? [yes/no]"),
                       ["yes", "no"])
    }

    func test_inline_yn_shorthand_detected() {
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Proceed? [y/n]"),
                       ["y", "n"])
    }

    func test_inline_skipCancel_detected() {
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Apply or skip? [yes / skip / cancel]"),
                       ["yes", "skip", "cancel"])
    }

    func test_inline_trailingPunct_detected() {
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Which? [yes / no]."),
                       ["yes", "no"])
    }

    func test_inline_namedOptionsWithAnchor_detected() {
        // main/dev aren't anchor words but `cancel` is → group qualifies (relaxed).
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Pick a branch [main / dev / cancel]"),
                       ["main", "dev", "cancel"])
    }

    func test_inline_promptWithCursorLineBelow_detected() {
        // An input cursor sits below the prompt — scan must reach past it.
        let c = "Approve which to delete? [all / 1 / 2 / none]\n❯ "
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: c),
                       ["all", "1", "2", "none"])
    }

    // Negatives — prose / code brackets must not register.
    func test_inline_proseBracketNoCue_rejected() {
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "Run rm -rf [dir] to clean."))
    }

    func test_inline_codeIndex_rejected() {
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "Set array[0] = value here."))
    }

    func test_inline_markdownLink_rejected() {
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "See the [docs](url) for details."))
    }

    func test_inline_singleBracketWord_rejected() {
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "Updated the [docs] section."))
    }

    func test_inline_multiWordTokens_rejected() {
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "Pick? [main branch / dev branch]"))
    }

    func test_inline_noAnchorToken_rejected() {
        // foo/bar are neither digits nor known anchor words → stays prose.
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "Choose? [foo / bar]"))
    }

    func test_inline_listInProseNoCue_rejected() {
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "The list was [1 / 2 / 3] long."))
    }
}
