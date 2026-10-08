import XCTest
@testable import Quip

/// PRD broadcast-and-search US-107: an unmodified library prompt is pasted by
/// id so the Mac fills its placeholders per window; any other text is sent as
/// written, and the sheet names the placeholders that stay unfilled.
final class BroadcastRouteTests: XCTestCase {
    private let source = BroadcastSource(promptID: "status", body: "Summarise {{folder}} for {{agent}}.")

    // MARK: Route

    func test_anUnmodifiedPromptIsPastedById() {
        XCTAssertEqual(BroadcastRoute.route(text: source.body, source: source), .pastePrompt(id: "status"))
    }

    func test_whitespaceAroundAnUnmodifiedPromptStillPastes() {
        XCTAssertEqual(BroadcastRoute.route(text: "\n  \(source.body) \n", source: source), .pastePrompt(id: "status"))
        let padded = BroadcastSource(promptID: "status", body: "  \(source.body)\n")
        XCTAssertEqual(BroadcastRoute.route(text: source.body, source: padded), .pastePrompt(id: "status"))
    }

    func test_editedTextIsSentAsWritten() {
        XCTAssertEqual(BroadcastRoute.route(text: " Summarise {{folder}} for me.\n", source: source),
                       .sendText("Summarise {{folder}} for me."))
        // A change inside the text is an edit, even when it is only spacing.
        XCTAssertEqual(BroadcastRoute.route(text: "Summarise  {{folder}} for {{agent}}.", source: source),
                       .sendText("Summarise  {{folder}} for {{agent}}."))
    }

    func test_plainTextWithNoSourceIsSentAsWritten() {
        XCTAssertEqual(BroadcastRoute.route(text: "  run the tests\n", source: nil), .sendText("run the tests"))
    }

    // MARK: Placeholder hint

    func test_editedTextNamesTheOnePlaceholderItLeavesUnfilled() {
        XCTAssertEqual(BroadcastRoute.placeholderHint(text: "Summarise {{folder}} for me.", source: source),
                       "Edited text is sent as written; {{folder}} is not filled.")
    }

    func test_twoPlaceholdersAreJoinedWithAnd() {
        XCTAssertEqual(BroadcastRoute.placeholderHint(text: "Summarise {{folder}} for {{agent}} now.", source: source),
                       "Edited text is sent as written; {{folder}} and {{agent}} are not filled.")
    }

    func test_threePlaceholdersInTypedTextAreAllNamed() {
        XCTAssertEqual(BroadcastRoute.placeholderHint(text: "{{folder}} {{agent}} {{date}}", source: nil),
                       "Edited text is sent as written; {{folder}}, {{agent}} and {{date}} are not filled.")
    }

    func test_pastThreePlaceholdersTheRestAreCounted() {
        XCTAssertEqual(BroadcastRoute.placeholderHint(text: "{{folder}} {{agent}} {{date}} {{cwd}} {{clipboard}}",
                                                      source: nil),
                       "Edited text is sent as written; {{folder}}, {{agent}}, {{date}} and 2 more are not filled.")
    }

    func test_namesAreListedOnceInLowercaseInFirstAppearanceOrder() {
        XCTAssertEqual(BroadcastRoute.placeholderHint(text: "{{ Agent }} in {{FOLDER}}, again {{agent}}", source: nil),
                       "Edited text is sent as written; {{agent}} and {{folder}} are not filled.")
    }

    func test_anUnmodifiedPromptWithPlaceholdersHasNoHint() {
        XCTAssertNil(BroadcastRoute.placeholderHint(text: source.body, source: source))
        XCTAssertNil(BroadcastRoute.placeholderHint(text: " \(source.body)\n", source: source))
    }

    func test_textWithoutAValidPlaceholderHasNoHint() {
        XCTAssertNil(BroadcastRoute.placeholderHint(text: "run the tests", source: nil))
        XCTAssertNil(BroadcastRoute.placeholderHint(text: "empty {{ }} braces", source: nil))
        XCTAssertNil(BroadcastRoute.placeholderHint(text: "a {{1x}} name", source: source))
    }
}
