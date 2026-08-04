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

    func test_isInteractiveMultiSelect_navFooterWidget_true() {
        // Claude Code's interactive checkbox widget — arrow/space/enter, NOT typed text.
        let content = """
        What's making Settings hard to understand?
        ❯ 1. [ ] Cryptic labels/wording
          2. [ ] Too many / unclear tabs
          3. [ ] Can't find things
        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        XCTAssertTrue(NumberedPromptDetector.isMultiSelect(in: content))
        XCTAssertTrue(NumberedPromptDetector.isInteractiveMultiSelect(in: content))
    }

    func test_isInteractiveMultiSelect_cursorCaretWidget_true() {
        // No footer, but a caret on a checkbox line still marks the interactive widget.
        let content = """
        Pick items:
        ❯ 1. [ ] alpha
          2. [ ] beta
        """
        XCTAssertTrue(NumberedPromptDetector.isInteractiveMultiSelect(in: content))
    }

    func test_isInteractiveMultiSelect_plainCheckboxMenu_false() {
        // Checkbox tokens but no widget signature (no nav footer, no caret) →
        // a text menu the user types into, not the interactive widget.
        let content = """
        Which to delete?
        1. [ ] G1 caches
        2. [ ] G2 backups
        """
        XCTAssertTrue(NumberedPromptDetector.isMultiSelect(in: content))
        XCTAssertFalse(NumberedPromptDetector.isInteractiveMultiSelect(in: content))
    }

    func test_isInteractiveMultiSelect_singleSelectWidget_false() {
        // Interactive but NOT multi-select (no checkboxes) → false.
        let content = """
        Apply this change?
        ❯ 1. Yes
          2. No
        Enter to select · ↑/↓ to navigate
        """
        XCTAssertFalse(NumberedPromptDetector.isInteractiveMultiSelect(in: content))
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

    func test_inline_trailingColon_detected() {
        // Canonical CLI prompt shape: `… [yes/no]:` (apt/npm/shell `read`).
        // The trailing colon must not block the bracketed choice.
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Continue? [yes/no]:"),
                       ["yes", "no"])
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Proceed? [y/n]: "),
                       ["y", "n"])
    }

    func test_inline_colonInProseNoCue_rejected() {
        // A colon after a bracket is NOT enough on its own — still needs a cue.
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "Ratio was [1/2]: large."))
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

    // MARK: - Inline PARENTHESIZED choice prompts (§18.3, US-001)

    func test_inlineParen_continueYesNo_detected() {
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Continue? (yes/no)"),
                       ["yes", "no"])
    }

    func test_inlineParen_digitsAndWords_detected() {
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Approve which? (all / 1 / 2 / none)"),
                       ["all", "1", "2", "none"])
    }

    func test_inlineParen_ynShorthand_detected() {
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Proceed? (y/n)"),
                       ["y", "n"])
    }

    // Negatives — parenthesized prose / code must not register.
    func test_inlineParen_codeCallNoCue_rejected() {
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "printf(a/b) returns void."))
    }

    func test_inlineParen_namedNoAnchor_rejected() {
        // main/dev are neither digits nor anchor words → stays prose.
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "Pick? (main / dev)"))
    }

    func test_inlineParen_ratioInProseNoCue_rejected() {
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "The ratio (1/2) is small."))
    }

    func test_inlineBracket_stillDetected_afterParenSupport() {
        // Bracketed detection unchanged once paren support lands.
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Continue? [yes/no]"),
                       ["yes", "no"])
    }

    // MARK: - Same-line trailing prompt cursor (US-003)

    func test_inlineBracket_sameLineCursor_detected() {
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Continue? [yes/no] ❯"),
                       ["yes", "no"])
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Which? [1 / 2 / 3] ›"),
                       ["1", "2", "3"])
    }

    func test_inlineParen_sameLineCursor_detected() {
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Proceed? (y/n) > "),
                       ["y", "n"])
        XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: "Continue? (yes/no) ❯ "),
                       ["yes", "no"])
    }

    func test_inline_sameLineCursor_proseGlyph_rejected() {
        // A glyph that is part of prose after the bracket is still rejected —
        // the trailing text carries letters, which fail the token charset guard.
        XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: "See [docs](url) › home."))
    }

    func test_inline_sameLineCursor_fingerprint_nonNil() {
        // fingerprint stays in agreement (non-nil) for same-line-cursor prompts.
        XCTAssertNotNil(NumberedPromptDetector.fingerprint(in: "Continue? [yes/no] ❯"))
        XCTAssertNotNil(NumberedPromptDetector.fingerprint(in: "Proceed? (y/n) > "))
        XCTAssertNil(NumberedPromptDetector.fingerprint(in: "See [docs](url) › home."))
    }

    // MARK: - Parenthesized prompt fingerprint lockstep (US-002)

    func test_inlineParen_fingerprint_nonNil() {
        XCTAssertNotNil(NumberedPromptDetector.fingerprint(in: "Continue? (yes/no)"))
        XCTAssertNotNil(NumberedPromptDetector.fingerprint(in: "Approve which? (all / 1 / 2 / none)"))
        XCTAssertNotNil(NumberedPromptDetector.fingerprint(in: "Proceed? (y/n)"))
    }

    func test_inlineParen_fingerprint_agreesWithDetect() {
        // Every paren prompt detectInlineOptions catches has a non-nil
        // fingerprint; every paren prose it rejects has a nil fingerprint.
        for p in ["Continue? (yes/no)", "Approve which? (all / 1 / 2 / none)", "Proceed? (y/n)"] {
            XCTAssertNotNil(NumberedPromptDetector.detectInlineOptions(in: p))
            XCTAssertNotNil(NumberedPromptDetector.fingerprint(in: p),
                            "detected paren prompt must have a fingerprint: \(p)")
        }
        for p in ["printf(a/b) returns void.", "Pick? (main / dev)",
                  "The ratio (1/2) is small.", "call foo(a/b) now."] {
            XCTAssertNil(NumberedPromptDetector.detectInlineOptions(in: p))
            XCTAssertNil(NumberedPromptDetector.fingerprint(in: p),
                         "rejected paren prose must have a nil fingerprint: \(p)")
        }
    }

    func test_inlineParen_fingerprint_stableAcrossAnsiAndCursor() {
        // Surrounding ANSI codes, a trailing cursor line, and trailing spaces are
        // all noise — the fingerprint must not move.
        let plain = NumberedPromptDetector.fingerprint(in: "Continue? (yes/no)")
        XCTAssertNotNil(plain)
        XCTAssertEqual(plain, NumberedPromptDetector.fingerprint(in: "\u{1B}[36mContinue? (yes/no)\u{1B}[0m"))
        XCTAssertEqual(plain, NumberedPromptDetector.fingerprint(in: "Continue? (yes/no)\n❯ "))
        XCTAssertEqual(plain, NumberedPromptDetector.fingerprint(in: "Continue? (yes/no)   "))
    }

    func test_inlineParen_fingerprint_changesWhenTokensChange() {
        let two = NumberedPromptDetector.fingerprint(in: "Continue? (yes/no)")
        let three = NumberedPromptDetector.fingerprint(in: "Continue? (yes/no/cancel)")
        XCTAssertNotNil(two)
        XCTAssertNotNil(three)
        XCTAssertNotEqual(two, three)
    }

    func test_inlineParen_fingerprint_changesWhenChoiceTextChanges() {
        // Same option tokens, different question → different fingerprint.
        let a = NumberedPromptDetector.fingerprint(in: "Continue? (yes/no)")
        let b = NumberedPromptDetector.fingerprint(in: "Abort the run? (yes/no)")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b)
    }

    func test_inlineParen_proseFingerprint_nil() {
        // A prose string with parens but no prompt → nil (agrees with detect).
        XCTAssertNil(NumberedPromptDetector.fingerprint(in: "call foo(a/b) now."))
    }

    // MARK: - v2 regression matrix (US-004)

    /// One table mapping realistic Claude/Codex/shell prompt strings to their
    /// expected chips (or nil), pinning the v2 detector behavior so a future edit
    /// can't silently regress a real prompt shape. Every chip row also proves
    /// fingerprint(in:) is non-nil and every nil row proves it is nil — so
    /// detect↔fingerprint agreement is asserted across the whole matrix.
    ///
    /// Coverage spans every v2 capability: bracket + paren groups (US-001),
    /// digits + words, yes/no shorthand, trailing period/question/colon and a
    /// same-line cursor glyph (US-003), a multi-line prompt with the input cursor
    /// on the line below, plus prose bracket/paren non-prompts that must stay nil.
    /// fingerprint non-nil/nil per row is the US-002 lockstep proof.
    func test_v2RegressionMatrix_detectAndFingerprintInLockstep() {
        // (input, expected chips or nil, label)
        let matrix: [(String, [String]?, String)] = [
            // — bracket shapes —
            ("Continue? [yes/no]",                                   ["yes", "no"],                            "bracket yes/no"),
            ("Approve which to delete? [all / 1 / 2 / 3 / none / pick]",
                                                                     ["all", "1", "2", "3", "none", "pick"],   "bracket digits+words"),
            ("Proceed? [y/n]",                                       ["y", "n"],                               "bracket y/n shorthand"),
            ("Which? [yes / no].",                                   ["yes", "no"],                            "bracket trailing period"),
            ("Proceed? [y/n]?",                                      ["y", "n"],                               "bracket trailing question"),
            ("Continue? [yes/no]:",                                  ["yes", "no"],                            "bracket trailing colon"),
            ("Continue? [yes/no] ❯",                                 ["yes", "no"],                            "bracket same-line cursor (US-003)"),
            // — paren shapes (US-001) —
            ("Continue? (yes/no)",                                   ["yes", "no"],                            "paren yes/no (US-001)"),
            ("Approve which? (all / 1 / 2 / none)",                  ["all", "1", "2", "none"],                "paren digits+words (US-001)"),
            ("Proceed? (y/n)",                                       ["y", "n"],                               "paren y/n shorthand (US-001)"),
            ("Proceed? (y/n) > ",                                    ["y", "n"],                               "paren same-line cursor (US-003)"),
            // — multi-line: input cursor on the line below the choice —
            ("Approve which to delete? [all / 1 / 2 / none]\n❯ ",    ["all", "1", "2", "none"],                "multi-line cursor below"),
            // — prose / code non-prompts (must stay nil, ≥3) —
            ("printf(a/b) returns void.",                            nil,                                      "paren code call (no cue)"),
            ("The ratio (1/2) is small.",                            nil,                                      "paren ratio prose (no cue)"),
            ("Run rm -rf [dir] to clean.",                           nil,                                      "bracket prose (no cue)"),
            ("See [docs](url) › home.",                              nil,                                      "bracket+glyph prose (US-003 neg)"),
        ]

        for (input, expected, label) in matrix {
            XCTAssertEqual(NumberedPromptDetector.detectInlineOptions(in: input), expected,
                           "detectInlineOptions mismatch for [\(label)]: \(input)")
            if expected == nil {
                XCTAssertNil(NumberedPromptDetector.fingerprint(in: input),
                             "nil-chip row must have a nil fingerprint [\(label)]: \(input)")
            } else {
                XCTAssertNotNil(NumberedPromptDetector.fingerprint(in: input),
                                "chip row must have a non-nil fingerprint [\(label)]: \(input)")
            }
        }
    }

    // MARK: - Live Claude Code widgets (captured 2026-08-03, v2.1.220)

    /// Verbatim capture of a real AskUserQuestion MULTI-select, read off a live
    /// iTerm2 session (trailing spaces stripped — every detector collapses
    /// whitespace). The hand-written fixtures above got three things wrong that
    /// this one gets right, and the phone is the peer that renders chips from
    /// this detector, so it locks the shape here too:
    ///   • the checked box is `[✔]` (U+2714), not `[✓]` / `[x]`
    ///   • options carry description lines between them
    ///   • an unnumbered `Submit` row sits under the last option
    private let liveMultiSelect = """
    ←  ☒ Fruit  ✔ Submit  →

    Which fruits do you want?

    ❯ 1. [✔] Apple
      Crisp, common, keeps well.
      2. [ ] Banana
      Soft, sweet, no peel tools needed.
      3. [ ] Cherry
      Small, tart-sweet, has pits.
      4. [ ] Durian
      Strong smell, custard texture, divisive.
      5. [ ] Type something
         Submit
    ──────────────────────────────────────────────
      6. Chat about this

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """

    /// The same widget in SINGLE-select form — no checkboxes, same meta rows.
    private let liveSingleSelect = """
     ☐ Pick

    Which one you pick?

    ❯ 1. Alpha
         First option.
      2. Beta
         Second option.
      3. Gamma
         Third option.
      4. Type something.
    ──────────────────────────────────────────────
      5. Chat about this

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """

    func test_liveMultiSelect_detectsCheckboxOptionsOnly() {
        // 6 ("Chat about this") carries no checkbox and is below the divider, so
        // it stays out of a checkbox run.
        XCTAssertEqual(NumberedPromptDetector.detect(in: liveMultiSelect), [1, 2, 3, 4, 5])
        XCTAssertTrue(NumberedPromptDetector.isMultiSelect(in: liveMultiSelect))
        XCTAssertTrue(NumberedPromptDetector.isInteractiveMultiSelect(in: liveMultiSelect))
    }

    /// The U+2714 regression: before this was recognised, the checked line was
    /// not even counted as a checkbox line, which broke the run AND made the
    /// phone seed its picks from an empty set.
    func test_liveMultiSelect_heavyCheckMarkCountsAsChecked() {
        XCTAssertEqual(NumberedPromptDetector.checkedOptions(in: liveMultiSelect), [1])
        XCTAssertEqual(MultiSelectSync.initialPicks(liveContent: liveMultiSelect), [1])
        XCTAssertEqual(NumberedPromptDetector.cursorOption(in: liveMultiSelect), 1)
    }

    func test_liveMultiSelect_hasSubmitRow() {
        XCTAssertTrue(NumberedPromptDetector.hasSubmitRow(in: liveMultiSelect))
        XCTAssertEqual(NumberedPromptDetector.lastOption(in: liveMultiSelect), 5)
    }

    /// A checkbox menu with no Submit row keeps the plain contract (Return
    /// confirms in place) — the two dialects must stay distinguishable.
    func test_plainCheckboxMenu_hasNoSubmitRow() {
        let content = """
        Which to delete?
        ❯ 1. [ ] G1 caches
          2. [ ] G2 backups
        """
        XCTAssertFalse(NumberedPromptDetector.hasSubmitRow(in: content))
    }

    func test_liveSingleSelect_notMultiSelect() {
        XCTAssertTrue(NumberedPromptDetector.isMultiSelect(in: liveSingleSelect) == false)
        XCTAssertEqual(NumberedPromptDetector.cursorOption(in: liveSingleSelect), 1)
        XCTAssertNotNil(NumberedPromptDetector.fingerprint(in: liveSingleSelect))
    }

    /// The review step Claude shows after Submit. The Mac presses Return again
    /// only when it can see this screen, so the phone-side detector must agree
    /// on what it looks like.
    func test_liveConfirmStep_isSubmitConfirmPrompt() {
        let review = """
        Review your answers

         ● Which fruits do you want?
           → Apple, Cherry

        Ready to submit your answers?

        ❯ 1. Submit answers
          2. Cancel
        """
        XCTAssertTrue(NumberedPromptDetector.isSubmitConfirmPrompt(in: review))
        XCTAssertFalse(NumberedPromptDetector.isSubmitConfirmPrompt(in: liveMultiSelect))
    }

    /// Terminals pad the buffer to the full window height, which pushes the
    /// prompt past the trailing scan window. The Mac trims that at the read
    /// (KeystrokeInjector.readContent) — this pins WHY it has to.
    func test_blankPaddedWidget_detectsNothing() {
        let padded = liveMultiSelect + String(repeating: "\n", count: 30)
        XCTAssertNil(NumberedPromptDetector.detect(in: padded))
        XCTAssertNil(NumberedPromptDetector.fingerprint(in: padded))
    }
}
