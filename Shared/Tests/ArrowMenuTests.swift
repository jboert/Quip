import XCTest
@testable import Quip

/// Q-89: Yes/No answers for arrow-key menus, numbered or not.
final class ArrowMenuTests: XCTestCase {
    private func plan(_ answer: ArrowMenu.Answer, _ lines: [String], agentCLI: Bool = true) -> ArrowMenu.Plan {
        ArrowMenu.plan(answer, content: lines.joined(separator: "\n"), agentCLI: agentCLI)
    }

    // MARK: Menus that get arrow keys

    func test_unnumberedMenu_cursorOnYes() {
        let screen = ["Start a cloud session?", "", "❯ Yes", "  No"]
        XCTAssertEqual(plan(.yes, screen), .keys(["return"]))
        XCTAssertEqual(plan(.no, screen), .keys(["down", "return"]))
    }

    func test_unnumberedMenu_cursorOnNo_walksUp() {
        XCTAssertEqual(plan(.yes, ["Proceed?", "  Yes", "❯ No"]), .keys(["up", "return"]))
    }

    func test_numberedClaudeMenu_usesArrowsNotDigits() {
        let screen = ["Do you want to proceed?", "❯ 1. Yes",
                      "  2. Yes, and don't ask again this session",
                      "  3. No, and tell Claude what to do differently (esc)"]
        XCTAssertEqual(plan(.yes, screen), .keys(["return"]))
        XCTAssertEqual(plan(.no, screen), .keys(["down", "down", "return"]))
    }

    func test_codexTrustMenu_synonyms() {
        let screen = ["Trust this folder?", "› 1. Trust and continue", "  2. Back to Agent Command Center",
                      "  enter continue · esc back"]
        XCTAssertEqual(plan(.yes, screen), .keys(["return"]))
        XCTAssertEqual(plan(.no, screen), .keys(["down", "return"]))
    }

    func test_exactYesBeatsASynonymAboveIt() {
        XCTAssertEqual(plan(.yes, ["❯ Continue later", "  Yes", "  No"]), .keys(["down", "return"]))
    }

    func test_doNotCountsAsNo() {
        XCTAssertEqual(plan(.no, ["❯ Allow", "  Do not allow"]), .keys(["down", "return"]))
    }

    func test_borderedDialog() {
        let screen = ["╭──────────────╮", "│ Approve?     │", "│ ❯ Yes        │", "│   No         │", "╰──────────────╯"]
        XCTAssertEqual(plan(.no, screen), .keys(["down", "return"]))
    }

    // MARK: Screens that keep typing y / n

    func test_plainYNPrompt_typesTheLetter() {
        XCTAssertEqual(plan(.yes, ["Overwrite file? (y/n)"]), .typeLetter)
    }

    func test_codexComposer_isNotAYesNoMenu() {
        XCTAssertEqual(plan(.yes, ["› Ask Codex to do anything", "  GPT-6.1-Sol high · weekly 62% left"]),
                       .typeLetter)
    }

    func test_claudeEmptyInputBox_isNotAMenu() {
        XCTAssertEqual(plan(.yes, ["────────", "❯ ", "────────"]), .typeLetter)
    }

    func test_answeredMenuInScrollbackAboveTheComposer_isIgnored() {
        let screen = ["❯ Yes", "  No", "", "• Done.", "› Ask Codex to do anything", "  GPT-6.1-Sol high"]
        XCTAssertEqual(plan(.yes, screen), .typeLetter)
    }

    func test_singleCursorRow_isNotAMenu() {
        XCTAssertNil(ArrowMenu.detect(in: "❯ Yes"))
    }

    func test_shellWindow_neverGetsArrows() {
        // ↑ + Return at a shell prompt re-runs the last history command.
        XCTAssertEqual(plan(.no, ["❯ Yes", "  No", "$ "], agentCLI: false), .typeLetter)
    }

    func test_oneTimeRowBeatsAPersistentOne() {
        XCTAssertEqual(plan(.yes, ["❯ Allow always", "  Allow once", "  Deny"]), .keys(["down", "return"]))
        XCTAssertEqual(plan(.yes, ["❯ Yes, and don't ask again", "  Yes", "  No"]), .keys(["down", "return"]))
    }

    // MARK: Refusals

    func test_menuWithoutTheRequestedAnswer_sendsNothing() {
        XCTAssertEqual(plan(.no, ["❯ Allow once", "  Allow always"]), .noMatchingRow)
    }

    // MARK: Detection

    func test_detect_stripsNumberingAndFindsTheCursor() {
        XCTAssertEqual(ArrowMenu.detect(in: "  1. Yes\n❯ 2. No"), ArrowMenu.Menu(labels: ["Yes", "No"], cursor: 1))
    }

    func test_detect_questionDirectlyAboveIsNotARow() {
        XCTAssertEqual(ArrowMenu.detect(in: "Proceed?\n❯ Yes\n  No"), ArrowMenu.Menu(labels: ["Yes", "No"], cursor: 0))
    }

    func test_isYesNoMenu() {
        XCTAssertTrue(ArrowMenu.isYesNoMenu(in: "❯ Yes\n  No"))
        XCTAssertFalse(ArrowMenu.isYesNoMenu(in: "❯ claude-opus\n  claude-sonnet"))
        XCTAssertFalse(ArrowMenu.isYesNoMenu(in: "plain output"))
    }
}
