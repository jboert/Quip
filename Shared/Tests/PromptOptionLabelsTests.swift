import XCTest
@testable import Quip

/// Locks `NumberedPromptDetector.optionLabels(in:)`, the option text the Mac
/// puts in a push body so "1 / 2 / 3" lock-screen buttons mean something.
final class PromptOptionLabelsTests: XCTestCase {

    func test_labels_fromClaudeMenu() throws {
        let content = """
        Do you want to proceed?
        ❯ 1. Yes
          2. Yes, and don't ask again this session
          3. No, and tell Claude what to do differently
        """
        let labels = try XCTUnwrap(NumberedPromptDetector.optionLabels(in: content))
        XCTAssertEqual(labels[1], "Yes")
        XCTAssertEqual(labels[2], "Yes, and don't ask again…")
        XCTAssertEqual(labels[3], "No, and tell Claude what to…")
        XCTAssertEqual(labels.count, 3)
    }

    func test_labels_nilWithoutPrompt() {
        XCTAssertNil(NumberedPromptDetector.optionLabels(in: "1. not a prompt\nprose"))
        XCTAssertNil(NumberedPromptDetector.optionLabels(in: ""))
    }

    func test_label_stripsNumberSeparatorAndCheckbox() {
        XCTAssertEqual(NumberedPromptDetector.optionLabel(fromNormalized: "1. [ ] Delete cache"), "Delete cache")
        XCTAssertEqual(NumberedPromptDetector.optionLabel(fromNormalized: "12) Keep"), "Keep")
        XCTAssertEqual(NumberedPromptDetector.optionLabel(fromNormalized: "2. [✔] Done"), "Done")
    }

    func test_label_cutsAtMaxLength() {
        let long = "1. abcdefghijklmnopqrstuvwxyz0123456789"
        XCTAssertEqual(NumberedPromptDetector.optionLabel(fromNormalized: long, maxLength: 10), "abcdefghi…")
        XCTAssertEqual(NumberedPromptDetector.optionLabel(fromNormalized: "1. short", maxLength: 10), "short")
    }
}
