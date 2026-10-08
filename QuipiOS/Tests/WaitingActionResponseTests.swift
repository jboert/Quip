import XCTest
import UserNotifications
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

    func test_replyField_whereAFourthSlotIsFree() {
        let byId = Dictionary(uniqueKeysWithValues: WaitingNotificationCategory.makeCategories().map { ($0.identifier, $0) })
        func hasReply(_ id: String) -> Bool {
            byId[id]?.actions.contains { $0 is UNTextInputNotificationAction && $0.identifier == "QUIP_ACTION_REPLY" } ?? false
        }
        XCTAssertTrue(hasReply("waiting.yn"))
        XCTAssertTrue(hasReply("waiting.12"))
        XCTAssertTrue(hasReply("waiting.123"))
        XCTAssertTrue(hasReply("waiting.text"))
        XCTAssertFalse(hasReply("waiting.1234"), "four numbered buttons fill the cap")
        let reply = byId["waiting.text"]?.actions.first
        XCTAssertTrue(reply?.options.contains(.authenticationRequired) ?? false,
                      "free text into a terminal needs the phone unlocked")
        XCTAssertEqual(byId["waiting.many"]?.actions.count, 0, "a bundle has no single answer")
    }

    func test_newChoiceIdentifiers() {
        XCTAssertEqual(WaitingActionResponse.choiceThree.rawIdentifier, "QUIP_ACTION_CHOICE_3")
        XCTAssertEqual(WaitingActionResponse.choiceFour.rawIdentifier, "QUIP_ACTION_CHOICE_4")
    }

    func test_categoriesCoverEveryActionIdentifierUsedByAPNs() {
        let categories = WaitingNotificationCategory.makeCategories()
        XCTAssertEqual(Set(categories.map(\.identifier)),
                       ["waiting_for_input", "waiting.yn", "waiting.12", "waiting.123", "waiting.1234",
                        "waiting.text", "waiting.many"])
        for c in categories {
            XCTAssertLessThanOrEqual(c.actions.count, 4, "\(c.identifier): iOS shows at most four actions")
        }

        let actionIDs = Set(categories.flatMap { $0.actions.map(\.identifier) })
        for response in [WaitingActionResponse.yes, .no, .choiceOne, .choiceTwo, .choiceThree, .choiceFour] {
            XCTAssertTrue(actionIDs.contains(response.rawIdentifier),
                          "\(response) must be actionable from a delivered notification")
        }
    }
}
