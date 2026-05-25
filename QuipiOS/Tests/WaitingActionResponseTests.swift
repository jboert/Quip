import XCTest
@testable import Quip

/// Locks the notification-action mapping: identifier round-trip and the
/// `quick_action` wire string each lock-screen answer dispatches. (§3.2)
final class WaitingActionResponseTests: XCTestCase {

    func test_identifierRoundTrip_allCases() {
        let all: [WaitingActionResponse] = [.yes, .no, .choiceOne, .choiceTwo, .choiceThree, .choiceFour]
        for r in all {
            XCTAssertEqual(WaitingActionResponse(actionId: r.rawIdentifier), r,
                           "\(r) must round-trip through its rawIdentifier")
        }
    }

    func test_unknownIdentifier_returnsNil() {
        XCTAssertNil(WaitingActionResponse(actionId: "QUIP_ACTION_BOGUS"))
    }

    func test_quickActionStrings() {
        XCTAssertEqual(WaitingActionResponse.yes.quickAction, "press_y")
        XCTAssertEqual(WaitingActionResponse.no.quickAction, "press_n")
        XCTAssertEqual(WaitingActionResponse.choiceOne.quickAction, "select_1")
        XCTAssertEqual(WaitingActionResponse.choiceTwo.quickAction, "select_2")
        XCTAssertEqual(WaitingActionResponse.choiceThree.quickAction, "select_3")
        XCTAssertEqual(WaitingActionResponse.choiceFour.quickAction, "select_4")
    }

    func test_newChoiceIdentifiers() {
        XCTAssertEqual(WaitingActionResponse.choiceThree.rawIdentifier, "QUIP_ACTION_CHOICE_3")
        XCTAssertEqual(WaitingActionResponse.choiceFour.rawIdentifier, "QUIP_ACTION_CHOICE_4")
    }
}
