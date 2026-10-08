import XCTest
@testable import Quip

/// Q-56: a push can show the question a prompt asks, never its option rows.
final class PromptPreviewTests: XCTestCase {

    func test_numberedPrompt_returnsTheQuestionAboveTheOptions() {
        let content = """
        Some earlier output
        Which file should I edit?
        ❯ 1. Sources/App.swift
          2. Sources/Main.swift
          3. Cancel
        Enter to select · Esc to cancel
        """
        XCTAssertEqual(PromptPreview.line(in: content), "Which file should I edit?")
    }

    func test_plainQuestion_returnsTheLastReadableLine() {
        let content = "Working…\n\nDo you want me to run the tests now?\n❯ \n"
        XCTAssertEqual(PromptPreview.line(in: content), "Do you want me to run the tests now?")
    }

    func test_ansiAndBoxDrawingAreStripped() {
        let content = "╭──────────────╮\n│ \u{1B}[1mApply the migration?\u{1B}[0m │\n╰──────────────╯\n  1. Yes\n  2. No\n"
        XCTAssertEqual(PromptPreview.line(in: content), "Apply the migration?")
    }

    func test_chromeAndEmptyPanesGiveNil() {
        XCTAssertNil(PromptPreview.line(in: ""))
        XCTAssertNil(PromptPreview.line(in: "❯ \n? for shortcuts\n"))
    }

    func test_longQuestionIsTruncated() {
        let long = String(repeating: "word ", count: 40)
        let line = try! XCTUnwrap(PromptPreview.line(in: long + "\n  1. Yes\n"))
        XCTAssertLessThanOrEqual(line.count, 90)
        XCTAssertTrue(line.hasSuffix("…"))
    }

    func test_checkboxRowsCountAsOptions() {
        let content = "Pick the targets\n[ ] iOS\n[x] Mac\nSpace to select"
        XCTAssertEqual(PromptPreview.line(in: content), "Pick the targets")
    }
}
