import XCTest
@testable import Quip

/// Locks the `.quippack` bundle format (§6.1): round-trip (incl. prompt
/// metadata + custom buttons), empty arms, and rejection of newer schemas /
/// malformed data.
final class SharedPromptPackTests: XCTestCase {

    private func sampleButton() -> CustomButton {
        CustomButton(id: UUID(), label: "Yes", systemImage: nil, payload: .keystroke(action: "press_y"))
    }

    func test_roundTrip_promptsAndButtons() throws {
        let pack = SharedPromptPack(
            name: "My Pack",
            prompts: [PromptEntry(id: "ship", label: "Ship", body: "ship it",
                                  tags: ["release"], targetAgent: "claude", description: "go")],
            buttons: [sampleButton()]
        )
        let data = try pack.encoded()
        let restored = try SharedPromptPack.decode(data)
        XCTAssertEqual(restored.name, "My Pack")
        XCTAssertEqual(restored.prompts.count, 1)
        XCTAssertEqual(restored.prompts[0].tags, ["release"])
        XCTAssertEqual(restored.prompts[0].targetAgent, "claude")
        XCTAssertEqual(restored.buttons.count, 1)
        XCTAssertEqual(restored.buttons[0].label, "Yes")
        XCTAssertEqual(restored.buttons[0].payload, .keystroke(action: "press_y"))
    }

    func test_roundTrip_emptyButtons() throws {
        let pack = SharedPromptPack(prompts: [PromptEntry(id: "p", label: "P", body: "b")], buttons: [])
        let restored = try SharedPromptPack.decode(try pack.encoded())
        XCTAssertEqual(restored.prompts.count, 1)
        XCTAssertTrue(restored.buttons.isEmpty)
    }

    func test_roundTrip_emptyPrompts() throws {
        let pack = SharedPromptPack(prompts: [], buttons: [sampleButton()])
        let restored = try SharedPromptPack.decode(try pack.encoded())
        XCTAssertTrue(restored.prompts.isEmpty)
        XCTAssertEqual(restored.buttons.count, 1)
    }

    func test_decode_newerSchema_throws() throws {
        let json = #"{"schema":2,"prompts":[],"buttons":[]}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertThrowsError(try SharedPromptPack.decode(data)) { error in
            XCTAssertEqual(error as? SharedPromptPack.PackError, .unsupportedSchema(2))
        }
    }

    func test_decode_malformed_throws() throws {
        let data = try XCTUnwrap("not json at all".data(using: .utf8))
        XCTAssertThrowsError(try SharedPromptPack.decode(data))
    }

    func test_uniquePromptID() {
        XCTAssertEqual(SharedPromptPack.uniquePromptID(desired: "ship", existing: []), "ship")
        XCTAssertEqual(SharedPromptPack.uniquePromptID(desired: "ship", existing: ["ship"]), "ship-2")
        XCTAssertEqual(SharedPromptPack.uniquePromptID(desired: "ship", existing: ["ship", "ship-2"]), "ship-3")
        XCTAssertEqual(SharedPromptPack.uniquePromptID(desired: "new", existing: ["ship"]), "new")
    }

    func test_reminted_changesIdKeepsContent() {
        let b = sampleButton()
        let r = SharedPromptPack.reminted(b)
        XCTAssertNotEqual(r.id, b.id)
        XCTAssertEqual(r.label, b.label)
        XCTAssertEqual(r.payload, b.payload)
    }

    // MARK: - Q-27b: re-importing a pack must not duplicate it

    /// Importing the same pack twice used to suffix a copy of every prompt
    /// (`ship`, `ship-2`, …). A prompt whose label AND body are already in the
    /// library is now skipped — whatever id the earlier import gave it.
    func test_importPlan_skipsPromptsAlreadyInstalled() {
        let pack = SharedPromptPack(prompts: [
            PromptEntry(id: "ship", label: "Ship", body: "ship it"),
            PromptEntry(id: "test", label: "Test", body: "run the tests"),
        ])
        let library = [PromptEntry(id: "ship-2", label: "Ship", body: "ship it")]
        let plan = SharedPromptPack.importPlan(for: pack, existingPrompts: library, existingButtons: [])
        XCTAssertEqual(plan.prompts.map(\.id), ["test"])
        XCTAssertEqual(plan.alreadyInstalledPrompts, 1)
    }

    /// Never clobber: same id, DIFFERENT content is still a new prompt, added
    /// under a suffixed id exactly as before.
    func test_importPlan_changedContentUnderTakenIdIsAddedNotOverwritten() {
        let pack = SharedPromptPack(prompts: [PromptEntry(id: "ship", label: "Ship", body: "ship it v2")])
        let library = [PromptEntry(id: "ship", label: "Ship", body: "ship it")]
        let plan = SharedPromptPack.importPlan(for: pack, existingPrompts: library, existingButtons: [])
        XCTAssertEqual(plan.prompts.map(\.id), ["ship-2"])
        XCTAssertEqual(plan.prompts.first?.body, "ship it v2")
        XCTAssertEqual(plan.alreadyInstalledPrompts, 0)
    }

    /// A pack that carries the same prompt twice adds it once, and two
    /// different prompts wanting one id still get distinct ids.
    func test_importPlan_dedupesWithinThePackAndKeepsIdsUnique() {
        let pack = SharedPromptPack(prompts: [
            PromptEntry(id: "a", label: "A", body: "one"),
            PromptEntry(id: "a", label: "A", body: "one"),
            PromptEntry(id: "a", label: "A", body: "two"),
        ])
        let plan = SharedPromptPack.importPlan(for: pack, existingPrompts: [], existingButtons: [])
        XCTAssertEqual(plan.prompts.map(\.id), ["a", "a-2"])
        XCTAssertEqual(plan.alreadyInstalledPrompts, 1)
    }

    /// Buttons were re-minted with fresh UUIDs on every import, so each
    /// re-import appended another copy of every button. A button with the same
    /// label, icon and payload as one already on the phone is now skipped.
    func test_importPlan_skipsButtonsAlreadyInstalled() {
        let installed = sampleButton()
        let fresh = CustomButton(id: UUID(), label: "No", systemImage: nil, payload: .keystroke(action: "press_n"))
        let pack = SharedPromptPack(buttons: [
            CustomButton(id: UUID(), label: "Yes", systemImage: nil, payload: .keystroke(action: "press_y")),
            fresh,
        ])
        let plan = SharedPromptPack.importPlan(for: pack, existingPrompts: [], existingButtons: [installed])
        XCTAssertEqual(plan.buttons.map(\.label), ["No"])
        XCTAssertNotEqual(plan.buttons.first?.id, fresh.id)  // still re-minted
        XCTAssertEqual(plan.alreadyInstalledButtons, 1)
    }

    func test_importPlan_everythingInstalledIsEmpty() {
        let p = PromptEntry(id: "p", label: "P", body: "b")
        let b = sampleButton()
        let plan = SharedPromptPack.importPlan(for: SharedPromptPack(prompts: [p], buttons: [b]),
                                               existingPrompts: [p], existingButtons: [b])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.alreadyInstalledPrompts + plan.alreadyInstalledButtons, 2)
    }

    func test_decode_legacySchema1_succeeds() throws {
        // Minimal schema-1 pack written without optional name/createdAt.
        let json = #"{"schema":1,"prompts":[],"buttons":[]}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let pack = try SharedPromptPack.decode(data)
        XCTAssertTrue(pack.isEmpty)
        XCTAssertNil(pack.name)
    }
}
