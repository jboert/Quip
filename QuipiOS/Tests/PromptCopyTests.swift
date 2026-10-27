import XCTest
@testable import Quip

/// "Make my own copy" of a VibeCut prompt survives the next sync (Q-80).
final class PromptCopyTests: XCTestCase {
    private let inherited = PromptEntry(
        id: "vibecut__ship-it", label: "Ship it", body: "run tests",
        tags: ["vibecut", "project:orchard-api", "purpose:release", "needs:git"],
        targetAgent: "claude", description: "Release helper")

    func test_idComesFromTheEditedLabel() {
        let copy = PromptCopy.ownCopy(of: inherited, label: "My ship it", body: "edited", existingIDs: [])
        XCTAssertEqual(copy.id, "My-ship-it")
        XCTAssertEqual(copy.label, "My ship it")
        XCTAssertEqual(copy.body, "edited")
    }

    func test_reservedPrefixNeverSurvives() {
        let typed = PromptCopy.ownCopy(of: inherited, label: "vibecut__vibecut__ship", body: "b", existingIDs: [])
        XCTAssertEqual(typed.id, "ship")
        let onlyPrefix = PromptCopy.ownCopy(of: inherited, label: "vibecut__", body: "b", existingIDs: [])
        XCTAssertFalse(onlyPrefix.id.hasPrefix("vibecut__"))
        XCTAssertEqual(onlyPrefix.id, "ship-it")
    }

    func test_collisionGetsNumberedSuffix() {
        let taken: Set<String> = ["mine", "mine-2"]
        let copy = PromptCopy.ownCopy(of: inherited, label: "mine", body: "b", existingIDs: taken)
        XCTAssertEqual(copy.id, "mine-3")
    }

    func test_vibecutTagDroppedOthersKept() {
        let copy = PromptCopy.ownCopy(of: inherited, label: "mine", body: "b", existingIDs: [])
        XCTAssertEqual(copy.tags, ["project:orchard-api", "purpose:release", "needs:git"])
        XCTAssertFalse(copy.isInherited)
        XCTAssertEqual(copy.targetAgent, "claude")
        XCTAssertEqual(copy.description, "Release helper")
    }

    func test_onlyVibecutTagLeavesNilTags() {
        let plain = PromptEntry(id: "vibecut__a", label: "A", body: "x", tags: ["vibecut"])
        XCTAssertNil(PromptCopy.ownCopy(of: plain, label: "A2", body: "x", existingIDs: []).tags)
    }

    func test_emptyLabelFallsBackToInheritedIDWithoutPrefix() {
        let copy = PromptCopy.ownCopy(of: inherited, label: "  ", body: "b", existingIDs: [])
        XCTAssertEqual(copy.id, "ship-it")
        XCTAssertEqual(copy.label, "Ship it")
        let unusable = PromptCopy.ownCopy(of: inherited, label: "!!!", body: "b", existingIDs: ["ship-it"])
        XCTAssertEqual(unusable.id, "ship-it-2")
    }
}
