import XCTest
@testable import Quip

/// The Slash Commands list's row actions and swipe rule (Q-51 / US-209).
final class SlashRowActionsTests: XCTestCase {
    func test_menuOffersPinOrRemoveByRowAndEditOnlyForCustoms() {
        XCTAssertEqual(SlashRowActions.menu(inRow: false, isCustom: false), [.send, .sendTo, .pinToRow])
        XCTAssertEqual(SlashRowActions.menu(inRow: true, isCustom: false), [.send, .sendTo, .removeFromRow])
        XCTAssertEqual(SlashRowActions.menu(inRow: true, isCustom: true), [.send, .sendTo, .removeFromRow, .edit])
    }

    func test_swipeRightSendsAndSwipeLeftManages() {
        XCTAssertEqual(SlashRowActions.leadingSwipe, [.sendTo])
        XCTAssertEqual(SlashRowActions.trailingSwipe(inRow: true, isCustom: true), [.edit, .removeFromRow])
        XCTAssertEqual(SlashRowActions.trailingSwipe(inRow: false, isCustom: false), [.pinToRow])
        let sending: Set<SlashRowAction> = [.send, .sendTo]
        for inRow in [false, true] {
            for isCustom in [false, true] {
                XCTAssertTrue(SlashRowActions.trailingSwipe(inRow: inRow, isCustom: isCustom).allSatisfy { !sending.contains($0) })
            }
        }
    }
}
