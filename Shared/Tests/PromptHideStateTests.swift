import XCTest
@testable import Quip

final class PromptHideStateTests: XCTestCase {

    private func entry(_ id: String) -> PromptEntry { PromptEntry(id: id, label: id, body: "b") }

    func testDecodeAndEncodeRoundTrip() {
        XCTAssertEqual(PromptHideState.decode("[]"), [])
        XCTAssertEqual(PromptHideState.decode("[\"a\",\"b\"]"), ["a", "b"])
        XCTAssertEqual(PromptHideState.encode(["b", "a"]), "[\"a\",\"b\"]")  // sorted
    }

    func testDecodeGarbageIsEmpty() {
        XCTAssertEqual(PromptHideState.decode("not json"), [])
        XCTAssertEqual(PromptHideState.decode(""), [])
    }

    func testToggleAddsAndRemoves() {
        let afterAdd = PromptHideState.toggled("x", in: "[]")
        XCTAssertTrue(PromptHideState.isHidden("x", in: afterAdd))
        let afterRemove = PromptHideState.toggled("x", in: afterAdd)
        XCTAssertFalse(PromptHideState.isHidden("x", in: afterRemove))
        XCTAssertEqual(afterRemove, "[]")
    }

    func testVisibleFiltersHidden() {
        let prompts = [entry("a"), entry("vibecut__b"), entry("c")]
        let visible = PromptHideState.visible(prompts, hiddenJSON: "[\"vibecut__b\"]")
        XCTAssertEqual(visible.map(\.id), ["a", "c"])
    }

    func testVisibleNoHiddenReturnsAll() {
        let prompts = [entry("a"), entry("b")]
        XCTAssertEqual(PromptHideState.visible(prompts, hiddenJSON: "[]").count, 2)
    }

    func testPruneDropsAbsentIds() {
        // "gone" no longer exists in the catalog -> pruned out.
        let pruned = PromptHideState.pruned(hiddenJSON: "[\"a\",\"gone\"]", presentIDs: ["a", "b"])
        XCTAssertEqual(pruned, "[\"a\"]")
    }

    func testPruneReturnsNilWhenUnchanged() {
        XCTAssertNil(PromptHideState.pruned(hiddenJSON: "[\"a\"]", presentIDs: ["a", "b"]))
        XCTAssertNil(PromptHideState.pruned(hiddenJSON: "[]", presentIDs: ["a"]))
    }
}
