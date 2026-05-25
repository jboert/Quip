import XCTest
@testable import Quip

/// Locks `QuipMacApp.answerStillValid` — the §3.2 gate that decides whether a
/// phone's one-tap answer may be injected given the live terminal content.
final class AnswerRevalidationTests: XCTestCase {

    private let numbered = "Pick one:\n❯ 1. Yes\n  2. No\n  3. Cancel"
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
}
