import XCTest
@testable import Quip

/// Locks `ImageUploadFailure.classify(reason:)` so the recovery chip
/// in PendingImagePreviewStrip routes the user to the right action
/// for each error class. (§L.)
final class ImageUploadFailureTests: XCTestCase {

    func test_watchdogTimeout_classifiesAsTimeout() {
        // The 10s watchdog message includes a debug stage — pattern-
        // match must survive arbitrary stage names.
        let r = "no response (last stage: sent, awaiting ack)"
        XCTAssertEqual(ImageUploadFailure.classify(reason: r), .timeout)
    }

    func test_connectionTimedOut_classifiesAsTimeout() {
        XCTAssertEqual(ImageUploadFailure.classify(reason: "connection timed out"), .timeout)
    }

    func test_unknownWindow_classified() {
        XCTAssertEqual(ImageUploadFailure.classify(reason: "unknown window"), .unknownWindow)
    }

    func test_windowNoLongerExists_classifiedAsUnknownWindow() {
        XCTAssertEqual(ImageUploadFailure.classify(reason: "Window no longer exists"), .unknownWindow)
    }

    func test_invalidImageData_classified() {
        XCTAssertEqual(ImageUploadFailure.classify(reason: "invalid image data"), .invalidData)
    }

    func test_invalidBase64_classified() {
        XCTAssertEqual(ImageUploadFailure.classify(reason: "invalid base64 payload"), .invalidData)
    }

    func test_couldNotSave_classified() {
        XCTAssertEqual(ImageUploadFailure.classify(reason: "could not save image"), .macDiskWrite)
    }

    func test_writeFailed_classified() {
        XCTAssertEqual(ImageUploadFailure.classify(reason: "write failed"), .macDiskWrite)
    }

    func test_tooLarge_classified() {
        XCTAssertEqual(ImageUploadFailure.classify(reason: "image too large to send"), .tooLarge)
        XCTAssertEqual(ImageUploadFailure.classify(reason: "dropping oversized message"), .tooLarge)
    }

    func test_unknownReason_fallsThroughToOther() {
        XCTAssertEqual(ImageUploadFailure.classify(reason: "Mac is grumpy today"), .other)
    }

    func test_caseInsensitive() {
        // Defensive: error strings sometimes come back capitalized.
        XCTAssertEqual(ImageUploadFailure.classify(reason: "NO RESPONSE (last stage: ...)"), .timeout)
        XCTAssertEqual(ImageUploadFailure.classify(reason: "INVALID IMAGE DATA"), .invalidData)
    }

    func test_actionLabels_nonEmpty_exceptOther() {
        // Catch-all .other intentionally has no action button — the
        // raw reason text already tells the user something. Every
        // other category must offer a recovery action.
        XCTAssertFalse(ImageUploadFailure.timeout.actionLabel.isEmpty)
        XCTAssertFalse(ImageUploadFailure.unknownWindow.actionLabel.isEmpty)
        XCTAssertFalse(ImageUploadFailure.invalidData.actionLabel.isEmpty)
        XCTAssertFalse(ImageUploadFailure.macDiskWrite.actionLabel.isEmpty)
        XCTAssertFalse(ImageUploadFailure.tooLarge.actionLabel.isEmpty)
        XCTAssertEqual(ImageUploadFailure.other.actionLabel, "")
    }
}
