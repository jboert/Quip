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

    func test_multiSelectSync_alreadyCorrect_noKeystrokes() {
        // Desired == live checked set {1,2}: nothing to toggle, no submit.
        XCTAssertEqual(MultiSelectSync.keystrokes(desired: Set([1, 2]), liveContent: preChecked),
                       [])
    }

    func test_multiSelectSync_addOne_keepsPreChecked() {
        // Keep 1 & 2, add 3. Cursor on 2 → down to 3, space, return.
        XCTAssertEqual(MultiSelectSync.keystrokes(desired: Set([1, 2, 3]), liveContent: preChecked),
                       ["down", "space", "return"])
    }

    func test_multiSelectSync_replaceSelection_togglesDiff() {
        // Desired {3} from pre-checked {1,2}, cursor 2: toggle 1,2 off + 3 on,
        // ascending cursor order.
        XCTAssertEqual(MultiSelectSync.keystrokes(desired: Set([3]), liveContent: preChecked),
                       ["space", "down", "space", "down", "space", "return"])
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
}
