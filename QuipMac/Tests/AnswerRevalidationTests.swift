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
}
