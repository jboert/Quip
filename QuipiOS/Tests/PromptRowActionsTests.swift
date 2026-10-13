import XCTest
@testable import Quip

/// The Prompts hub's row actions and swipe rule (Q-51 / US-209).
final class PromptRowActionsTests: XCTestCase {
    func test_menuOrderForAVisibleAndAHiddenPrompt() {
        XCTAssertEqual(PromptRowActions.menu(hidden: false),
                       [.paste, .pasteAndSend, .sendTo, .broadcast, .edit, .hide, .delete])
        XCTAssertEqual(PromptRowActions.menu(hidden: true).dropLast().last, .show)
    }

    func test_swipeRightSendsAndSwipeLeftManages() {
        XCTAssertEqual(PromptRowActions.leadingSwipe, [.sendTo, .pasteAndSend, .broadcast])
        XCTAssertEqual(PromptRowActions.trailingSwipe(hidden: false), [.delete, .hide, .edit])
        XCTAssertEqual(PromptRowActions.trailingSwipe(hidden: true), [.delete, .show, .edit])
        let sending: Set<PromptRowAction> = [.paste, .pasteAndSend, .sendTo, .broadcast]
        XCTAssertTrue(PromptRowActions.leadingSwipe.allSatisfy(sending.contains))
        XCTAssertTrue(PromptRowActions.trailingSwipe(hidden: false).allSatisfy { !sending.contains($0) })
    }

    func test_aFullSwipeRightNeverSendsByItself() {
        XCTAssertEqual(PromptRowActions.leadingSwipe.first, .sendTo)
    }
}
