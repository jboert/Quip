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

    // MARK: Search (PRD broadcast-and-search, US-102)

    func test_aTagOnlyMatchIsFound() {
        let tagged = PromptEntry(id: "cut", label: "Cut a build", body: "archive and upload", tags: ["release"])
        let hub = PromptHub.sections(library + [tagged], hiddenJSON: "[]", store: [:],
                                     context: nil, query: "release", at: now)
        XCTAssertEqual(hub.visible.map(\.id), ["cut"])
    }

    func test_relevanceBeatsFrecencyWhileSearching() {
        // "ship" is used far more, but "Commit" is the other prompt's name;
        // "ship" only has the word in its body.
        let commit = PromptEntry(id: "commit", label: "Commit", body: "write the message")
        var store: PromptRanker.Store = [:]
        for _ in 0..<5 { store = PromptRanker.recording("ship", context: nil, at: now, in: store) }
        let prompts = library + [commit]
        let searching = PromptHub.sections(prompts, hiddenJSON: "[]", store: store,
                                           context: nil, query: "commit", at: now)
        XCTAssertEqual(searching.visible.map(\.id), ["commit", "ship"])
        let browsing = PromptHub.sections(prompts, hiddenJSON: "[]", store: store,
                                          context: nil, query: "", at: now)
        XCTAssertEqual(browsing.visible.first?.id, "ship")
    }

    func test_equallyGoodMatchesKeepFrecencyOrder() {
        let logs = PromptEntry(id: "logs", label: "First", body: "check the logs")
        let build = PromptEntry(id: "build", label: "Second", body: "check the build")
        let store = PromptRanker.recording("build", context: nil, at: now, in: [:])
        let hub = PromptHub.sections([logs, build], hiddenJSON: "[]", store: store,
                                     context: nil, query: "check", at: now)
        XCTAssertEqual(hub.visible.map(\.id), ["build", "logs"])
    }

    func test_wordsMatchInAnyOrder() {
        let hub = PromptHub.sections(library, hiddenJSON: "[]", store: [:],
                                     context: nil, query: "push ship", at: now)
        XCTAssertEqual(hub.visible.map(\.id), ["ship"])
    }

    func test_aMatchDeepInTheBodyShowsTheTextAroundIt() throws {
        let deep = PromptEntry(id: "deep", label: "Long one",
                               body: String(repeating: "filler words here ", count: 40) + "zebra at the end")
        let hub = PromptHub.sections([deep], hiddenJSON: "[]", store: [:],
                                     context: nil, query: "zebra", at: now)
        let excerpt = try XCTUnwrap(hub.notes["deep"]?.excerpt)
        XCTAssertTrue(excerpt.contains("zebra"))
        XCTAssertNil(hub.notes["deep"]?.closeMatch)
    }

    func test_aNameMatchNeedsNoNote() {
        let hub = PromptHub.sections(library, hiddenJSON: "[]", store: [:],
                                     context: nil, query: "ship", at: now)
        XCTAssertEqual(hub.visible.map(\.id), ["ship"])
        XCTAssertNil(hub.notes["ship"])
    }

    func test_aTypoMatchSaysSo() {
        let hub = PromptHub.sections(library, hiddenJSON: "[]", store: [:],
                                     context: nil, query: "reviw", at: now)
        XCTAssertEqual(hub.visible.map(\.id), ["review"])
        XCTAssertEqual(hub.notes["review"]?.closeMatch, "Close match: reviw → review")
    }

    func test_targetAgentAndDescriptionAreSearched() {
        let packed = PromptEntry(id: "pk", label: "Packed", body: "x", targetAgent: "codex",
                                 description: "Summarise yesterday")
        let byAgent = PromptHub.sections([packed], hiddenJSON: "[]", store: [:],
                                         context: nil, query: "codex", at: now)
        XCTAssertEqual(byAgent.visible.map(\.id), ["pk"])
        let byDescription = PromptHub.sections([packed], hiddenJSON: "[]", store: [:],
                                               context: nil, query: "yesterday", at: now)
        XCTAssertEqual(byDescription.visible.map(\.id), ["pk"])
    }

    func test_theCachedIndexFollowsLibraryChanges() {
        let cache = PromptSearchCache()
        _ = PromptHub.sections(library, hiddenJSON: "[]", store: [:],
                               context: nil, query: "ship", at: now, cache: cache)
        let added = library + [PromptEntry(id: "new", label: "Brand new", body: "")]
        let hub = PromptHub.sections(added, hiddenJSON: "[]", store: [:],
                                     context: nil, query: "brand", at: now, cache: cache)
        XCTAssertEqual(hub.visible.map(\.id), ["new"])
    }
}
