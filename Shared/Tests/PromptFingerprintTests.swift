import XCTest
@testable import Quip

/// Locks `NumberedPromptDetector.fingerprint(in:)` and `detectYesNo(in:)` —
/// the two helpers the Mac uses to re-validate a phone's one-tap answer
/// against the live prompt before injecting. (§3.2)
final class PromptFingerprintTests: XCTestCase {

    // MARK: - fingerprint

    func test_fingerprint_nilWhenNoPrompt() {
        XCTAssertNil(NumberedPromptDetector.fingerprint(in: "just some prose\nnothing here"))
        XCTAssertNil(NumberedPromptDetector.fingerprint(in: ""))
    }

    func test_fingerprint_stableAcrossMarkerMove() {
        // Same option set, the `❯` highlight on a different option, plus
        // injected ANSI color codes → identical fingerprint.
        let a = """
        Pick one:
        ❯ 1. Yes
          2. No
          3. Cancel
        """
        let b = """
        Pick one:
          1. Yes
        ❯ 2. No
          3. Cancel
        """
        // Same contiguous option set, marker on 3, wrapped in ANSI color codes.
        let c = "Pick one:\n  1. Yes\n  2. No\n\u{1B}[32m❯ 3. Cancel\u{1B}[0m"
        let fa = NumberedPromptDetector.fingerprint(in: a)
        XCTAssertNotNil(fa)
        XCTAssertEqual(fa, NumberedPromptDetector.fingerprint(in: b),
                       "marker position must not change the fingerprint")
        XCTAssertEqual(fa, NumberedPromptDetector.fingerprint(in: c),
                       "ANSI codes must not change the fingerprint")
    }

    func test_fingerprint_stableAcrossCodexMarkerMoveWithMultiDigitOptions() {
        let a = """
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
        let b = """
        Pick one:
          1. One
          2. Two
          3. Three
          4. Four
          5. Five
          6. Six
          7. Seven
          8. Eight
          9. Nine
        › 10. Ten
        """
        let fa = NumberedPromptDetector.fingerprint(in: a)
        XCTAssertNotNil(fa)
        XCTAssertEqual(fa, NumberedPromptDetector.fingerprint(in: b),
                       "marker position must not change the fingerprint for Codex-style menus")
    }

    func test_fingerprint_changesWhenOptionTextChanges() {
        let yes = "❯ 1. Yes\n  2. No"
        let proceed = "❯ 1. Proceed\n  2. No"
        XCTAssertNotEqual(NumberedPromptDetector.fingerprint(in: yes),
                          NumberedPromptDetector.fingerprint(in: proceed))
    }

    func test_fingerprint_changesWhenOptionCountChanges() {
        let two = "❯ 1. Yes\n  2. No"
        let three = "❯ 1. Yes\n  2. No\n  3. Cancel"
        XCTAssertNotEqual(NumberedPromptDetector.fingerprint(in: two),
                          NumberedPromptDetector.fingerprint(in: three))
    }

    func test_fingerprint_agreesWithDetect() {
        // When detect finds options, fingerprint must be non-nil; when it
        // doesn't, fingerprint must be nil. The two must never disagree.
        let prompt = "❯ 1. Yes\n  2. No"
        XCTAssertNotNil(NumberedPromptDetector.detect(in: prompt))
        XCTAssertNotNil(NumberedPromptDetector.fingerprint(in: prompt))

        let prose = "1. first thing\n2. second thing"  // no marker → not a prompt
        XCTAssertNil(NumberedPromptDetector.detect(in: prose))
        XCTAssertNil(NumberedPromptDetector.fingerprint(in: prose))
    }

    // MARK: - detectYesNo

    func test_detectYesNo_trueForYNPrompt() {
        XCTAssertTrue(NumberedPromptDetector.detectYesNo(in: "Do you want to proceed? (y/n)"))
        XCTAssertTrue(NumberedPromptDetector.detectYesNo(in: "Overwrite file? (Y/n)"))
        XCTAssertTrue(NumberedPromptDetector.detectYesNo(in: "Continue? (yes/no)"))
    }

    func test_detectYesNo_falseForNumberedPrompt() {
        XCTAssertFalse(NumberedPromptDetector.detectYesNo(in: "❯ 1. Yes\n  2. No"))
    }

    func test_detectYesNo_falseForProse() {
        XCTAssertFalse(NumberedPromptDetector.detectYesNo(in: "the function returns y/n internally"))
        XCTAssertFalse(NumberedPromptDetector.detectYesNo(in: ""))
    }

    func test_fingerprint_yesNo_nonNilAndStableAcrossANSI() {
        let fp = NumberedPromptDetector.fingerprint(in: "Proceed? (y/n)")
        XCTAssertNotNil(fp)
        XCTAssertEqual(fp, NumberedPromptDetector.fingerprint(in: "\u{1B}[0mProceed? (y/n)\u{1B}[0m"))
    }

    func test_fingerprint_yesNo_differsByPromptText() {
        XCTAssertNotEqual(NumberedPromptDetector.fingerprint(in: "Proceed? (y/n)"),
                          NumberedPromptDetector.fingerprint(in: "Overwrite file? (y/n)"))
    }
}
