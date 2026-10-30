import XCTest
@testable import Quip

/// Q-89: Yes / No are always there when a window waits and nothing better was found.
final class YesNoFallbackBarTests: XCTestCase {
    func test_waitingWithNoOptions_shows() {
        XCTAssertTrue(YesNoFallbackBar.shows(content: "Start a cloud session?", isWaiting: true, isAgent: false))
    }

    func test_unnumberedYesNoMenu_inAnAgent_showsEvenBeforeTheMacSaysWaiting() {
        XCTAssertTrue(YesNoFallbackBar.shows(content: "Start a cloud session?\n❯ Yes\n  No", isWaiting: false, isAgent: true))
    }

    func test_menuLookingTextInAShell_hides() {
        XCTAssertFalse(YesNoFallbackBar.shows(content: "❯ Yes\n  No\n$ ", isWaiting: false, isAgent: false))
    }

    func test_notWaitingAndNoMenu_hides() {
        XCTAssertFalse(YesNoFallbackBar.shows(content: "build finished", isWaiting: false, isAgent: true))
    }

    func test_numberedOptions_keepTheirOwnChips() {
        let menu = "Do you want to proceed?\n❯ 1. Yes\n  2. No"
        XCTAssertFalse(YesNoFallbackBar.shows(content: menu, isWaiting: true, isAgent: true))
    }

    func test_bracketedOptions_keepTheirOwnChips() {
        XCTAssertFalse(YesNoFallbackBar.shows(content: "Delete which? [all / 1 / 2 / none]", isWaiting: true, isAgent: true))
    }

    func test_buttonsSendTheMacsQuickActions() {
        XCTAssertEqual(YesNoFallbackBar.actions.map(\.action), ["press_y", "press_n", "press_up", "press_down"])
    }

    func test_arrowQuickButtons() {
        guard case .quickAction("press_up") = QuickButton.arrowUp.action,
              case .quickAction("press_down") = QuickButton.arrowDown.action else {
            return XCTFail("arrow buttons must send press_up / press_down")
        }
        XCTAssertEqual(QuickButton.arrowUp.category, .keystroke)
    }
}
