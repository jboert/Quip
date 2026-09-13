import XCTest
@testable import Quip

/// Locks `QuipMacApp.answerStillValid` — the §3.2 gate that decides whether a
/// phone's one-tap answer may be injected given the live terminal content.
final class AnswerRevalidationTests: XCTestCase {

    private let numbered = "Pick one:\n❯ 1. Yes\n  2. No\n  3. Cancel"
    private let codexNumbered = """
    Pick one:
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
    private let yesNo = "Overwrite file? (y/n)"

    func test_numbered_matchingFingerprint_andOptionPresent_injects() {
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: numbered))
        XCTAssertTrue(QuipMacApp.answerStillValid(action: "select_2",
                                                  expectedFingerprint: fp, liveContent: numbered))
    }

    func test_numbered_staleFingerprint_dropped() {
        // Phone saw a different prompt than what's live now.
        let stalePrompt = "Pick one:\n❯ 1. Continue\n  2. Stop"
        let staleFp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: stalePrompt))
        XCTAssertFalse(QuipMacApp.answerStillValid(action: "select_2",
                                                   expectedFingerprint: staleFp, liveContent: numbered))
    }

    func test_numbered_optionOutOfRange_dropped() {
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: numbered))
        // Live prompt has 1-3; select_5 is not an offered option.
        XCTAssertFalse(QuipMacApp.answerStillValid(action: "select_5",
                                                   expectedFingerprint: fp, liveContent: numbered))
    }

    func test_numbered_multiDigitOption_matchingFingerprint_injects() {
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: codexNumbered))
        XCTAssertTrue(QuipMacApp.answerStillValid(action: "select_10",
                                                  expectedFingerprint: fp,
                                                  liveContent: codexNumbered))
    }

    func test_selectedOptionNumber_parsesDynamicActions() {
        XCTAssertEqual(QuipMacApp.selectedOptionNumber(from: "select_5"), 5)
        XCTAssertEqual(QuipMacApp.selectedOptionNumber(from: "select_10"), 10)
        XCTAssertNil(QuipMacApp.selectedOptionNumber(from: "select_0"))
        XCTAssertNil(QuipMacApp.selectedOptionNumber(from: "select_x"))
        XCTAssertNil(QuipMacApp.selectedOptionNumber(from: "select_"))
    }

    func test_yesNo_matchingFingerprint_injects() {
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: yesNo))
        XCTAssertTrue(QuipMacApp.answerStillValid(action: "press_y",
                                                  expectedFingerprint: fp, liveContent: yesNo))
    }

    func test_promptGone_dropped() {
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: numbered))
        // Agent moved on — no prompt on screen now.
        XCTAssertFalse(QuipMacApp.answerStillValid(action: "select_1",
                                                   expectedFingerprint: fp, liveContent: "Working...\nDone."))
    }

    // MARK: - Multi-select (§18.2)

    private let checkboxMenu = """
    Which cleanup groups should I delete?
    1. [ ] G1 Xcode caches
    rm -rf the regenerable cache.
    2. [ ] G2 superseded backups
    delete the corrupted imports.
    3. [ ] G3 remote merged branch
    git push origin --delete it.
    """

    func test_selectedOptionNumbers_parsesMultiSubmit() {
        XCTAssertEqual(QuipMacApp.selectedOptionNumbers(from: "select_multi:1,3"), [1, 3])
        XCTAssertEqual(QuipMacApp.selectedOptionNumbers(from: "select_multi:2"), [2])
        XCTAssertNil(QuipMacApp.selectedOptionNumbers(from: "select_multi:"))
        XCTAssertNil(QuipMacApp.selectedOptionNumbers(from: "select_multi:1,x"))
        XCTAssertNil(QuipMacApp.selectedOptionNumbers(from: "select_multi:0,2")) // 0 invalid
        XCTAssertNil(QuipMacApp.selectedOptionNumbers(from: "select_2"))         // single, not multi
    }

    func test_multiSelect_isAnswerAction() {
        XCTAssertTrue(QuipMacApp.isAnswerAction("select_multi:1,3"))
    }

    func test_multiSelect_allOptionsOffered_matchingFingerprint_injects() {
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: checkboxMenu))
        XCTAssertTrue(QuipMacApp.answerStillValid(action: "select_multi:1,3",
                                                  expectedFingerprint: fp, liveContent: checkboxMenu))
    }

    func test_multiSelect_optionOutOfRange_dropped() {
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: checkboxMenu))
        // Live menu offers 1-3; option 5 isn't there.
        XCTAssertFalse(QuipMacApp.answerStillValid(action: "select_multi:1,5",
                                                   expectedFingerprint: fp, liveContent: checkboxMenu))
    }

    func test_multiSelect_staleFingerprint_dropped() {
        let stale = "Which to delete?\n1. [ ] A\n2. [ ] B"
        let staleFp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: stale))
        XCTAssertFalse(QuipMacApp.answerStillValid(action: "select_multi:1,2",
                                                   expectedFingerprint: staleFp, liveContent: checkboxMenu))
    }

    // MARK: - Inline bracketed prompts (§18.3)

    private let inlineMenu = "Approve which to delete? [all / 1 / 2 / 3 / none / pick]"

    func test_answerTextToken_parses() {
        XCTAssertEqual(QuipMacApp.answerTextToken(from: "answer_text:all"), "all")
        XCTAssertEqual(QuipMacApp.answerTextToken(from: "answer_text:cancel"), "cancel")
        XCTAssertNil(QuipMacApp.answerTextToken(from: "answer_text:"))
        XCTAssertNil(QuipMacApp.answerTextToken(from: "answer_text:bad token")) // interior space
        XCTAssertNil(QuipMacApp.answerTextToken(from: "select_2"))
    }

    func test_inline_isAnswerAction() {
        XCTAssertTrue(QuipMacApp.isAnswerAction("answer_text:all"))
    }

    func test_inline_wordAnswer_offered_injects() {
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: inlineMenu))
        XCTAssertTrue(QuipMacApp.answerStillValid(action: "answer_text:all",
                                                  expectedFingerprint: fp, liveContent: inlineMenu))
    }

    func test_inline_wordAnswer_notOffered_dropped() {
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: inlineMenu))
        // "yes" isn't offered by this menu.
        XCTAssertFalse(QuipMacApp.answerStillValid(action: "answer_text:yes",
                                                   expectedFingerprint: fp, liveContent: inlineMenu))
    }

    func test_inline_digitAnswer_routesViaSelectN_injects() {
        // A digit option in an inline prompt uses select_N and must validate even
        // though detect() (the numbered-run) is nil for an inline prompt.
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: inlineMenu))
        XCTAssertTrue(QuipMacApp.answerStillValid(action: "select_2",
                                                  expectedFingerprint: fp, liveContent: inlineMenu))
    }

    func test_inline_staleFingerprint_dropped() {
        let stale = "Continue? [yes/no]"
        let staleFp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: stale))
        XCTAssertFalse(QuipMacApp.answerStillValid(action: "answer_text:all",
                                                   expectedFingerprint: staleFp, liveContent: inlineMenu))
    }

    // MARK: - Interactive multi-select keystroke choreography (§18.2, US-004)
    //
    // The injector now diffs the desired FINAL selection against the widget's
    // live PRE-CHECKED set via MultiSelectSync.keystrokes — it never assumes an
    // all-unchecked start. `preChecked` renders options 1 & 2 as [✓] with the
    // cursor › on option 2 (matching the real Recommended-style prompt).

    private let preChecked = """
    Which files should I clean up?

      1. [✓] config.cache  (Recommended)
    › 2. [✓] build.artifacts  (Recommended)
      3. [ ] logs.txt
      4. [ ] user.data

    ↑/↓ to navigate · space to toggle · Enter to confirm
    """

    func test_multiSelectSync_alreadyCorrect_stillConfirms() {
        // Desired == live checked set {1,2}: nothing to toggle, but Submit must
        // still press Return to CONFIRM the widget — otherwise tapping Submit to
        // accept the pre-checked defaults injects nothing and the prompt hangs.
        XCTAssertEqual(MultiSelectSync.keystrokes(desired: Set([1, 2]), liveContent: preChecked),
                       ["return"])
    }

    func test_multiSelectSync_addOne_keepsPreChecked() {
        // Keep 1 & 2, add 3. Cursor on 2 → down to 3, space, return.
        XCTAssertEqual(MultiSelectSync.keystrokes(desired: Set([1, 2, 3]), liveContent: preChecked),
                       ["down", "space", "return"])
    }

    func test_multiSelectSync_replaceSelection_walksUpForAboveCursor() {
        // Desired {3} from pre-checked {1,2}, cursor on 2: option 1 is ABOVE the
        // cursor, so the walk must go UP to reach it. The old down-only code
        // clamped that move to zero and toggled the wrong rows.
        XCTAssertEqual(MultiSelectSync.keystrokes(desired: Set([3]), liveContent: preChecked),
                       ["up", "space", "down", "space", "down", "space", "return"])
    }

    /// Replay the emitted keys against a model widget (cursor + checked set) and
    /// assert the RESULTING checked set equals the desired set — the check that
    /// actually proves correctness, vs pinning the raw key array. (review H3)
    private func replay(_ keys: [String], startCursor: Int, checked: Set<Int>, optionCount: Int) -> Set<Int> {
        var cur = startCursor, set = checked
        for k in keys {
            switch k {
            case "down":  cur = min(optionCount, cur + 1)
            case "up":    cur = max(1, cur - 1)
            case "space": if set.contains(cur) { set.remove(cur) } else { set.insert(cur) }
            default:      break
            }
        }
        return set
    }

    func test_multiSelectSync_replayReachesDesired() {
        // preChecked: cursor on option 2, {1,2} pre-checked, 4 options.
        for desired: Set<Int> in [[1, 2], [1, 2, 3], [3], [2, 4], [1, 3, 4]] {
            let keys = MultiSelectSync.keystrokes(desired: desired, liveContent: preChecked)
            XCTAssertEqual(replay(keys, startCursor: 2, checked: [1, 2], optionCount: 4), desired,
                           "keys must land the widget on desired \(desired.sorted())")
        }
    }

    func test_multiSelectSync_emptyContent_startsUnchecked() {
        // No live checkbox state (empty content) → default cursor 1, empty
        // checked set: desired {1,2} toggles both on from the top.
        XCTAssertEqual(MultiSelectSync.keystrokes(desired: Set([1, 2]), liveContent: ""),
                       ["space", "down", "space", "return"])
    }

    func test_multiSelectDigitKeys_sortedPlusReturn() {
        XCTAssertEqual(QuipMacApp.multiSelectDigitKeys(picks: [2, 1]), ["1", "2", "return"])
        XCTAssertEqual(QuipMacApp.multiSelectDigitKeys(picks: []), [])
    }

    // MARK: - shouldPressReturnAfterPick

    /// Codex's `/model`: the digit selected a model AND advanced to the
    /// reasoning-level step. A Return here would confirm that step's default —
    /// captured live, which is how the bug was found.
    func test_pickCommit_screenAdvanced_sendsNothing() {
        let before = "Select Model and Effort\n› 1. sol (current)\n  2. terra\n  3. luna"
        let after = "Select Reasoning Level for luna\n  1. Low\n› 2. Medium (default)\n  3. High"
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: before))
        XCTAssertFalse(QuipMacApp.shouldPressReturnAfterPick(liveContent: after, expectedFingerprint: fp))
    }

    /// A menu that ignores a bare digit is still on screen — commit it.
    func test_pickCommit_samePromptStillUp_sendsReturn() {
        let fp = try! XCTUnwrap(NumberedPromptDetector.fingerprint(in: numbered))
        XCTAssertTrue(QuipMacApp.shouldPressReturnAfterPick(liveContent: numbered, expectedFingerprint: fp))
    }

    /// Claude's review step: the user's tap already committed to submitting.
    func test_pickCommit_reviewStep_sendsReturn() {
        let review = """
        Review your answers

         ● Which one you pick?
           → Beta

        Ready to submit your answers?

        ❯ 1. Submit answers
          2. Cancel
        """
        XCTAssertTrue(QuipMacApp.shouldPressReturnAfterPick(liveContent: review,
                                                            expectedFingerprint: "stale-hash"))
    }

    /// The prompt is gone entirely (Claude's single-select answers on the digit
    /// alone) — anything typed now lands in the next prompt's input box.
    func test_pickCommit_promptGone_sendsNothing() {
        XCTAssertFalse(QuipMacApp.shouldPressReturnAfterPick(
            liveContent: "⏺ User answered Claude's questions:\n  ⎿  · Which one you pick? → Beta",
            expectedFingerprint: "stale-hash"))
    }

    // MARK: - imageInjectionRoute

    /// Codex on iTerm2 keeps the proven clipboard-bytes route.
    func test_imageRoute_codexOnITerm2_pastesBytes() {
        XCTAssertEqual(QuipMacApp.imageInjectionRoute(cliKind: .codex, terminalApp: .iterm2),
                       .pasteImage)
    }

    /// The regression this fixes: Codex under Terminal.app used to take the
    /// paste route, which can only drive iTerm2, so the upload failed outright.
    /// Codex reads a typed absolute path itself (measured on codex-cli 0.146.0).
    func test_imageRoute_codexOnTerminalApp_fallsBackToTypedPath() {
        XCTAssertEqual(QuipMacApp.imageInjectionRoute(cliKind: .codex, terminalApp: .terminal),
                       .sendTextPath)
    }

    /// Every other CLI types the path on every host, as before.
    func test_imageRoute_nonCodex_alwaysTypesPath() {
        for kind in CLIKind.allCases where kind != .codex {
            for app in [TerminalApp.iterm2, .terminal, .claudeDesktop] {
                XCTAssertEqual(QuipMacApp.imageInjectionRoute(cliKind: kind, terminalApp: app),
                               .sendTextPath, "\(kind)/\(app) must type the path")
            }
        }
    }

    /// pasteImage can only drive iTerm2, so no route may send another host to it.
    func test_imageRoute_pasteOnlyEverTargetsITerm2() {
        for kind in CLIKind.allCases {
            for app in [TerminalApp.terminal, .claudeDesktop] {
                XCTAssertNotEqual(QuipMacApp.imageInjectionRoute(cliKind: kind, terminalApp: app),
                                  .pasteImage, "\(kind)/\(app) would paste into a host that can't")
            }
        }
    }

    // MARK: - trimTrailingBlankLines

    /// Terminals pad the buffer to the full window height. Unless that padding
    /// is dropped, the prompt sits past the detector's trailing scan window and
    /// EVERY re-validation fails.
    func test_trimTrailingBlankLines_restoresDetection() {
        let padded = numbered + String(repeating: "\n   ", count: 40)
        XCTAssertNil(NumberedPromptDetector.fingerprint(in: padded))
        let trimmed = KeystrokeInjector.trimTrailingBlankLines(padded)
        XCTAssertEqual(NumberedPromptDetector.fingerprint(in: trimmed),
                       NumberedPromptDetector.fingerprint(in: numbered))
    }

    func test_trimTrailingBlankLines_keepsInteriorBlanks() {
        XCTAssertEqual(KeystrokeInjector.trimTrailingBlankLines("a\n\nb\n\n  \n"), "a\n\nb")
        XCTAssertEqual(KeystrokeInjector.trimTrailingBlankLines(""), "")
    }
}
