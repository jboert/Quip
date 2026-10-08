import XCTest
@testable import Quip

/// PRD broadcast-and-search US-103: the Quick Buttons editor and the Add
/// Button sheet search through QuipSearch.
final class QuickButtonSearchTests: XCTestCase {
    private func labels(_ buttons: [QuickButton], _ query: String) -> [String] {
        QuickButtonSearch.filter(buttons, query: query).map { $0.label.isEmpty ? $0.displayName : $0.label }
    }

    // MARK: Built-in buttons

    func test_aBuiltInIsFoundByWhatItSends() {
        XCTAssertEqual(labels(QuickButton.allCases, "escape").first, "Esc")
        XCTAssertEqual(labels(QuickButton.allCases, "compact").first, "/compact")
    }

    func test_aBuiltInIsFoundByItsId() {
        XCTAssertEqual(labels(QuickButton.allCases, "yes").first, "Y")
    }

    func test_aBuiltInIsFoundByItsShortAndItsFullName() {
        XCTAssertEqual(labels(QuickButton.allCases, "ship").first, "/ship")
        XCTAssertEqual(labels(QuickButton.allCases, "commit push").first, "/ship")
    }

    func test_iconOnlyButtonsAreFoundByTheirSettingsName() {
        XCTAssertEqual(QuickButtonSearch.filter(QuickButton.allCases, query: "backspace").first, .backspace)
    }

    // MARK: Row Order slots

    private let customID = UUID()
    private var custom: CustomButton {
        CustomButton(id: customID, label: "Deploy", systemImage: nil,
                     payload: .rawText(text: "make deploy", autoSubmit: true))
    }

    private func rowIDs(_ slots: [QuickSlot], _ query: String) -> [String] {
        let rows = slots.map {
            QuickButtonSearch.row($0, customs: [customID: custom], promptLabels: ["ship-it": "Ship it"])
        }
        return QuickButtonSearch.filter(rows, query: query).map(\.slot.id)
    }

    func test_eachSlotKindIsSearchable() {
        let slots: [QuickSlot] = [.builtin(.yes), .custom(customID), .prompt(promptID: "ship-it"), .promptsPicker]
        XCTAssertEqual(rowIDs(slots, "yes"), ["b:yes"])
        XCTAssertEqual(rowIDs(slots, "deploy"), ["c:\(customID.uuidString)"], "custom label")
        XCTAssertEqual(rowIDs(slots, "make"), ["c:\(customID.uuidString)"], "custom payload")
        XCTAssertEqual(rowIDs(slots, "ship"), ["p:ship-it"], "prompt label")
        XCTAssertEqual(rowIDs(slots, "prompts").first, "pp")
    }

    func test_aPromptSlotTheMacHasNotSentIsFoundByItsId() {
        let rows = [QuickButtonSearch.row(.prompt(promptID: "weekly-plan"), customs: [:], promptLabels: [:])]
        XCTAssertEqual(QuickButtonSearch.filter(rows, query: "weekly").map(\.slot.id), ["p:weekly-plan"])
    }

    func test_spacersNeverMatchAQuery() {
        let spacer = QuickSlot.spacer(UUID())
        XCTAssertTrue(rowIDs([spacer], "spacer").isEmpty)
        XCTAssertEqual(rowIDs([spacer], ""), [spacer.id], "no query keeps every slot")
    }

    func test_noQueryKeepsTheRowOrder() {
        let slots: [QuickSlot] = [.promptsPicker, .builtin(.esc), .builtin(.yes)]
        XCTAssertEqual(rowIDs(slots, "  "), slots.map(\.id))
    }

    // MARK: Add Button sheet

    func test_theTopOfTheAddSheetIsSearchable() {
        let items: [QuickButtonSearch.AddItem] = [.customButton, .spacer, .onePrompt, .promptsPicker]
        XCTAssertEqual(QuickButtonSearch.filter(items, query: "spacer"), [.spacer])
        XCTAssertEqual(Set(QuickButtonSearch.filter(items, query: "prompt")), [.onePrompt, .promptsPicker])
        XCTAssertEqual(QuickButtonSearch.filter(items, query: "custom").first, .customButton)
    }
}
