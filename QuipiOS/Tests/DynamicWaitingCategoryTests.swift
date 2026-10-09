import XCTest
import UserNotifications
@testable import Quip

/// Q-60: the notification service extension builds a category per alert so
/// the long-press buttons carry the prompt's own answers. Locks the payload
/// parsing, the category shape, and the merge that keeps the static set and
/// recent dynamic ones alive across registrations.
final class DynamicWaitingCategoryTests: XCTestCase {

    private let info: [AnyHashable: Any] = [
        "quip_options": [1, 2, 3],
        "quip_option_labels": ["1": "Yes", "2": "Yes, don't ask again", "3": "No"],
    ]

    func test_payloadParsing() {
        XCTAssertEqual(WaitingNotificationCategory.options(from: info), [1, 2, 3])
        XCTAssertEqual(WaitingNotificationCategory.labels(from: info), [1: "Yes", 2: "Yes, don't ask again", 3: "No"])
        XCTAssertEqual(WaitingNotificationCategory.options(from: [:]), [])
        XCTAssertEqual(WaitingNotificationCategory.labels(from: ["quip_option_labels": ["x": "nope", "2": ""]]), [:])
    }

    func test_buttonsCarryTheLabels_andReplyWhileASlotIsFree() throws {
        let cat = try XCTUnwrap(WaitingNotificationCategory.dynamicCategory(
            options: [1, 2, 3], labels: [1: "Yes", 2: "Yes, don't ask again", 3: "No"]))
        XCTAssertTrue(cat.identifier.hasPrefix("waiting.dyn."))
        XCTAssertEqual(cat.actions.map(\.title), ["Yes", "Yes, don't ask again", "No", "Reply"])
        XCTAssertEqual(cat.actions.map(\.identifier),
                       ["QUIP_ACTION_CHOICE_1", "QUIP_ACTION_CHOICE_2", "QUIP_ACTION_CHOICE_3", "QUIP_ACTION_REPLY"],
                       "same identifiers as the static set, so the answer queue needs no change")
        XCTAssertTrue(cat.actions.last is UNTextInputNotificationAction)
        let four = try XCTUnwrap(WaitingNotificationCategory.dynamicCategory(
            options: [1, 2, 3, 4], labels: [1: "a", 2: "b", 3: "c", 4: "d"]))
        XCTAssertEqual(four.actions.count, 4, "four answers fill the cap: no Reply")
        XCTAssertFalse(four.actions.contains { $0 is UNTextInputNotificationAction })
    }

    func test_identifierIsStableAcrossLaunches_andDiffersPerLabelSet() throws {
        let a = try XCTUnwrap(WaitingNotificationCategory.dynamicCategory(options: [1, 2], labels: [1: "Yes", 2: "No"]))
        let b = try XCTUnwrap(WaitingNotificationCategory.dynamicCategory(options: [1, 2], labels: [1: "Yes", 2: "No"]))
        let c = try XCTUnwrap(WaitingNotificationCategory.dynamicCategory(options: [1, 2], labels: [1: "Yes", 2: "Cancel"]))
        XCTAssertEqual(a.identifier, b.identifier)
        XCTAssertNotEqual(a.identifier, c.identifier)
        XCTAssertEqual(WaitingNotificationCategory.fnv1a("1=Yes|2=No"), WaitingNotificationCategory.fnv1a("1=Yes|2=No"))
        XCTAssertEqual(WaitingNotificationCategory.fnv1a("").count, 8)
    }

    func test_staticSetSuffices_whenLabelsDoNotFitTheButtons() {
        XCTAssertNil(WaitingNotificationCategory.dynamicCategory(options: [1], labels: [1: "Only"]),
                     "one option is Reply-only on the Mac too")
        XCTAssertNil(WaitingNotificationCategory.dynamicCategory(options: [1, 2, 3, 4, 5],
                                                                 labels: [1: "a", 2: "b", 3: "c", 4: "d", 5: "e"]),
                     "five options have no button set")
        XCTAssertNil(WaitingNotificationCategory.dynamicCategory(options: [1, 2, 3], labels: [1: "Yes", 3: "No"]),
                     "a missing label would leave a button with no title")
        XCTAssertNil(WaitingNotificationCategory.dynamicCategory(options: [1, 2, 5], labels: [1: "a", 2: "b", 5: "c"]),
                     "option 5 has no button")
        XCTAssertEqual(WaitingNotificationCategory.dynamicCategory(options: [2, 3], labels: [2: "a", 3: "b"])?
                           .actions.map(\.identifier),
                       ["QUIP_ACTION_CHOICE_2", "QUIP_ACTION_CHOICE_3", "QUIP_ACTION_REPLY"],
                       "buttons keep the option's own number, so select_2 / select_3 go out")
        XCTAssertNil(WaitingNotificationCategory.dynamicCategory(options: [], labels: [:]))
    }

    func test_merge_keepsStaticAndRecentDynamic_andCaps() throws {
        let staticIds = Set(WaitingNotificationCategory.makeCategories().map(\.identifier))
        func dyn(_ i: Int) -> UNNotificationCategory {
            UNNotificationCategory(identifier: "waiting.dyn.\(String(format: "%08x", i))", actions: [],
                                   intentIdentifiers: [], options: [])
        }
        let stale = UNNotificationCategory(identifier: "waiting.12", actions: [], intentIdentifiers: [], options: [])
        let existing: Set<UNNotificationCategory> = [stale, dyn(1), dyn(2)]
        let merged = WaitingNotificationCategory.merged(existing: existing, adding: dyn(3))
        XCTAssertTrue(staticIds.isSubset(of: Set(merged.map(\.identifier))), "every static category survives")
        XCTAssertEqual(merged.first { $0.identifier == "waiting.12" }?.actions.count, 3,
                       "the app's definition of a static category wins over a stale one")
        for i in 1...3 { XCTAssertTrue(merged.contains { $0.identifier == dyn(i).identifier }) }

        let many: Set<UNNotificationCategory> = Set((1...WaitingNotificationCategory.dynamicKeep + 5).map(dyn))
        let capped = WaitingNotificationCategory.merged(existing: many, adding: dyn(999))
        let dynamic = capped.filter { $0.identifier.hasPrefix("waiting.dyn.") }
        XCTAssertEqual(dynamic.count, WaitingNotificationCategory.dynamicKeep)
        XCTAssertTrue(dynamic.contains { $0.identifier == dyn(999).identifier }, "the newcomer is never dropped")
        let none = WaitingNotificationCategory.merged(existing: [], adding: nil)
        XCTAssertEqual(Set(none.map(\.identifier)), staticIds)
    }
}
