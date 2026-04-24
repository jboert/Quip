import XCTest
@testable import Quip

/// Pins the heuristic that keeps mid-press pauses from wiping earlier
/// transcription. Captured from a device log where SFSpeechRecognizer
/// produced the partial sequence:
///     "First" → "First sentence" → "Second" (no isFinal between)
/// The "Second" line is the rollover this detector has to catch.
final class RecognizerRolloverTests: XCTestCase {

    func test_observed_device_rollover_is_detected() {
        XCTAssertTrue(RecognizerRollover.detects(previous: "First sentence",
                                                  current: "Second"))
    }

    func test_refinement_extending_previous_is_not_rollover() {
        // Normal recognizer progress: same first token, current is longer.
        XCTAssertFalse(RecognizerRollover.detects(previous: "First",
                                                   current: "First sentence"))
    }

    func test_identical_partial_is_not_rollover() {
        // Recognizer re-emits the same partial — must not double-commit.
        XCTAssertFalse(RecognizerRollover.detects(previous: "hello world",
                                                   current: "hello world"))
    }

    func test_empty_previous_is_not_rollover() {
        // First partial of a task has no previous high-water mark.
        XCTAssertFalse(RecognizerRollover.detects(previous: "",
                                                   current: "hello"))
    }

    func test_empty_current_is_not_rollover() {
        // Recognizer can emit an empty partial between utterances; stitching
        // already handles that case, so don't misread it as a rollover.
        XCTAssertFalse(RecognizerRollover.detects(previous: "hello world",
                                                   current: ""))
    }

    func test_same_first_token_shorter_current_is_not_rollover() {
        // Recognizer revised "hello world today" → "hello world" — same leading
        // token, so it's a revision not a rollover. Downstream stitcher handles.
        XCTAssertFalse(RecognizerRollover.detects(previous: "hello world today",
                                                   current: "hello world"))
    }

    func test_different_first_token_but_longer_is_not_rollover() {
        // If current is LONGER than previous even with a different first token,
        // it's likely recognizer converged on a better reading rather than a
        // pause-triggered reset. Stay on the strict "shorter + different" rule.
        XCTAssertFalse(RecognizerRollover.detects(previous: "I think",
                                                   current: "We think maybe so"))
    }

    func test_case_insensitive_first_token_match() {
        // Recognizer can capitalize mid-utterance ("hello" → "Hello there").
        // Must not treat that as a rollover just because of case.
        XCTAssertFalse(RecognizerRollover.detects(previous: "hello world",
                                                   current: "Hello"))
    }
}
