import XCTest
@testable import Quip

final class PromptHubTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let library = [
        PromptEntry(id: "ship", label: "Ship it", body: "run tests, commit, push"),
        PromptEntry(id: "review", label: "Review PR", body: "find risky changes"),
        PromptEntry(id: "old", label: "Old thing", body: "legacy"),
    ]

    func test_visibleAreRankedAndHiddenAreSeparate() {
        let store = PromptRanker.recording("review", context: "claude", at: now, in: [:])
        let hub = PromptHub.sections(library, hiddenJSON: "[\"old\"]", store: store,
                                     context: "claude", query: "", at: now)
        XCTAssertEqual(hub.visible.map(\.id), ["review", "ship"])
        XCTAssertEqual(hub.hidden.map(\.id), ["old"])
    }

    func test_searchFiltersBothSectionsByLabelBodyOrID() {
        let hub = PromptHub.sections(library, hiddenJSON: "[\"old\"]", store: [:],
                                     context: nil, query: "  LEGACY ", at: now)
        XCTAssertTrue(hub.visible.isEmpty)
        XCTAssertEqual(hub.hidden.map(\.id), ["old"])

        let byBody = PromptHub.sections(library, hiddenJSON: "[]", store: [:],
                                        context: nil, query: "risky", at: now)
        XCTAssertEqual(byBody.visible.map(\.id), ["review"])
    }

    func test_noHiddenPromptsGivesEmptyHiddenSection() {
        let hub = PromptHub.sections(library, hiddenJSON: "[]", store: [:],
                                     context: nil, query: "", at: now)
        XCTAssertEqual(hub.visible.count, 3)
        XCTAssertTrue(hub.hidden.isEmpty)
    }
}
