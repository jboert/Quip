import XCTest
@testable import Quip

/// Editing a keyboard button from the row (Q-67): customs in place, built-ins
/// as a custom copy that takes their slot and color.
final class QuickButtonEditTests: XCTestCase {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    func test_slashBuiltinCopiesItsCommandAndSubmit() {
        let plan = QuickButtonEdit.customCopy(of: .plan, id: id)
        XCTAssertEqual(plan?.payload, .slash(text: "/plan ", autoSubmit: false))
        XCTAssertEqual(plan?.label, "/plan")
        XCTAssertEqual(QuickButtonEdit.customCopy(of: .compact, id: id)?.payload,
                       .slash(text: "/compact", autoSubmit: true))
    }

    func test_copyKeepsTheBuiltinsAgents() {
        XCTAssertEqual(QuickButtonEdit.customCopy(of: .plan, id: id)?.agentIDs, ["claude"])
        XCTAssertEqual(QuickButtonEdit.customCopy(of: .model, id: id)?.agentIDs, ["claude", "codex"])
        XCTAssertNil(QuickButtonEdit.customCopy(of: .esc, id: id)?.agentIDs)
    }

    func test_numberBuiltinCopiesAsTextAndKeyAsKeystroke() {
        XCTAssertEqual(QuickButtonEdit.customCopy(of: .one, id: id)?.payload,
                       .rawText(text: "1", autoSubmit: true))
        let esc = QuickButtonEdit.customCopy(of: .esc, id: id)
        XCTAssertEqual(esc?.payload, .keystroke(action: "press_escape"))
        XCTAssertEqual(esc?.systemImage, "escape")
    }

    func test_iconOnlyBuiltinGetsItsLongNameAsLabel() {
        let back = QuickButtonEdit.customCopy(of: .backspace, id: id)
        XCTAssertEqual(back?.label, QuickButton.backspace.displayName)
        XCTAssertFalse(back?.label.isEmpty ?? true)
    }

    func test_broadcastAndPromptSlotsAreNotEditableHere() {
        XCTAssertNil(QuickButtonEdit.customCopy(of: .broadcast))
        XCTAssertNil(QuickButtonEdit.editable(.prompt(promptID: "p"), defs: []))
        XCTAssertNil(QuickButtonEdit.editable(.spacer(UUID()), defs: []))
        XCTAssertNil(QuickButtonEdit.editable(.custom(id), defs: []))
    }

    func test_savingACustomReplacesItsDefinitionAndKeepsTheRow() {
        let old = CustomButton(id: id, label: "Old", systemImage: nil, payload: .rawText(text: "a", autoSubmit: false))
        var new = old
        new.label = "New"
        new.payload = .rawText(text: "b", autoSubmit: true)
        let slots: [QuickSlot] = [.builtin(.yes), .custom(id)]
        let r = QuickButtonEdit.save(new, over: .custom(id), slots: slots, defs: [old], colors: [:])
        XCTAssertEqual(r.slots, slots)
        XCTAssertEqual(r.defs, [new])
    }

    func test_savingABuiltinPutsTheCopyInItsPlaceWithItsColor() {
        let plan = QuickSlot.builtin(.plan)
        let copy = QuickButtonEdit.customCopy(of: .plan, id: id)!
        var edited = copy
        edited.payload = .slash(text: "/plan careful ", autoSubmit: false)
        let r = QuickButtonEdit.save(edited, over: plan,
                                     slots: [.builtin(.yes), plan, .builtin(.esc)],
                                     defs: [], colors: [plan.id: "#FF0000"])
        XCTAssertEqual(r.slots, [.builtin(.yes), .custom(id), .builtin(.esc)])
        XCTAssertEqual(r.defs, [edited])
        XCTAssertEqual(r.colors, [QuickSlot.custom(id).id: "#FF0000"])
    }

    func test_removingDropsOnlyThatSlot() {
        let slots: [QuickSlot] = [.builtin(.yes), .custom(id), .builtin(.esc)]
        XCTAssertEqual(QuickButtonEdit.removing(.custom(id), from: slots), [.builtin(.yes), .builtin(.esc)])
    }

    func test_undoPutsARemovedSlotBackWhereItWas() {
        let slots: [QuickSlot] = [.builtin(.yes), .custom(id), .builtin(.esc)]
        let removed = QuickButtonEdit.removing(.custom(id), from: slots)
        XCTAssertEqual(QuickButtonEdit.restoring(.custom(id), at: 1, in: removed), slots)
        // Row shrank meanwhile: lands at the end. Already back: unchanged.
        XCTAssertEqual(QuickButtonEdit.restoring(.custom(id), at: 5, in: [.builtin(.yes)]),
                       [.builtin(.yes), .custom(id)])
        XCTAssertEqual(QuickButtonEdit.restoring(.custom(id), at: 0, in: slots), slots)
    }

    func test_addingASpacerPutsItRightAfterTheHeldButton() {
        let gap = UUID()
        let slots: [QuickSlot] = [.builtin(.yes), .custom(id), .builtin(.esc)]
        XCTAssertEqual(QuickButtonEdit.addingSpacer(after: .custom(id), in: slots, id: gap),
                       [.builtin(.yes), .custom(id), .spacer(gap), .builtin(.esc)])
        XCTAssertEqual(QuickButtonEdit.addingSpacer(after: .builtin(.esc), in: slots, id: gap).last,
                       .spacer(gap))
    }

    func test_addingASpacerAfterAMissingButtonAppendsIt() {
        let gap = UUID()
        XCTAssertEqual(QuickButtonEdit.addingSpacer(after: .builtin(.plan), in: [.builtin(.yes)], id: gap),
                       [.builtin(.yes), .spacer(gap)])
    }
}
