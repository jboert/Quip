import XCTest
@testable import Quip

/// PRD broadcast-and-search US-106: the suggestions under the Broadcast
/// sheet's prompt field.
final class BroadcastSuggestionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let library = [
        PromptEntry(id: "ship", label: "Ship it", body: "run tests, commit, push"),
        PromptEntry(id: "review", label: "Review PR", body: "find risky changes before the commit"),
        PromptEntry(id: "deploy", label: "Deploy", body: "ship the build to staging"),
        PromptEntry(id: "old", label: "Old thing", body: "legacy ship script"),
    ]

    private func used(_ counts: [String: Int]) -> PromptRanker.Store {
        var store: PromptRanker.Store = [:]
        for (id, times) in counts {
            for _ in 0..<times { store = PromptRanker.recording(id, context: nil, at: now, in: store) }
        }
        return store
    }

    private func suggest(_ draft: String, library: [PromptEntry]? = nil, hidden: Set<String> = [],
                         store: PromptRanker.Store = [:], chosenBody: String? = nil) -> BroadcastSuggestions.Result {
        BroadcastSuggestions.suggestions(draft: draft, library: library ?? self.library,
                                         hiddenJSON: PromptHideState.encode(hidden), store: store,
                                         context: "claude", at: now, chosenBody: chosenBody)
    }

    func test_anEmptyFieldShowsTheMostUsedShelf() {
        let store = used(["review": 3, "deploy": 1])
        for draft in ["", "  \n"] {
            let shelf = suggest(draft, store: store)
            XCTAssertEqual(shelf.kind, .mostUsed, draft)
            XCTAssertEqual(shelf.prompts.map(\.id), ["review", "deploy", "old", "ship"], draft)
        }
    }

    func test_oneCharacterShowsNothing() {
        // "👍🏽" is two scalars but one character.
        for draft in ["s", " s\n", "👍🏽"] {
            XCTAssertEqual(suggest(draft), BroadcastSuggestions.Result(kind: .none, prompts: []), draft)
        }
    }

    func test_twoOrMoreCharactersGiveMatchesBestFirst() {
        // "Old thing" and "Deploy" are used more, but only "Ship it" has the
        // word in its name; between the two body matches, usage decides.
        let store = used(["old": 5, "deploy": 2])
        for draft in ["sh", "ship", "  ship\n"] {
            let result = suggest(draft, store: store)
            XCTAssertEqual(result.kind, .matches, draft)
            XCTAssertEqual(result.prompts.map(\.id), ["ship", "old", "deploy"], draft)
        }
    }

    func test_neverMoreThanSixSuggestions() {
        let many = (0..<10).map { PromptEntry(id: "c\($0)", label: "Check \($0)", body: "check the logs") }
        let firstSix = ["c0", "c1", "c2", "c3", "c4", "c5"]
        XCTAssertEqual(suggest("", library: many).prompts.map(\.id), firstSix)
        XCTAssertEqual(suggest("check", library: many).prompts.map(\.id), firstSix)
        XCTAssertEqual(BroadcastSuggestions.limit, 6)
    }

    func test_hiddenPromptsAreNeverSuggested() {
        let store = used(["old": 5])
        XCTAssertEqual(suggest("", hidden: ["old"], store: store).prompts.map(\.id), ["deploy", "review", "ship"])
        XCTAssertEqual(suggest("ship", hidden: ["old"], store: store).prompts.map(\.id), ["ship", "deploy"])
        XCTAssertEqual(suggest("legacy", hidden: ["old"], store: store),
                       BroadcastSuggestions.Result(kind: .matches, prompts: []))
    }

    func test_theChosenPromptsOwnTextShowsNothing() {
        // Prompt files often end in a newline, and the field may not keep it.
        let body = "run tests, commit, push\n"
        for draft in [body, "run tests, commit, push", "  run tests, commit, push "] {
            XCTAssertEqual(suggest(draft, chosenBody: body), BroadcastSuggestions.Result(kind: .none, prompts: []),
                           draft)
        }
        // An edit brings the suggestions back, and so does clearing the field.
        let edited = suggest("run tests, push", chosenBody: body)
        XCTAssertEqual(edited.kind, .matches)
        XCTAssertEqual(edited.prompts.map(\.id), ["ship"])
        XCTAssertEqual(suggest("", chosenBody: body).kind, .mostUsed)
    }

    func test_aSharedSearchCacheGivesTheSameSuggestions() {
        let cache = PromptSearchCache()
        func cached(_ library: [PromptEntry]) -> BroadcastSuggestions.Result {
            BroadcastSuggestions.suggestions(draft: "ship", library: library, hiddenJSON: "[]", store: [:],
                                             context: "claude", at: now, cache: cache)
        }
        XCTAssertEqual(cached(library), suggest("ship"))
        let added = library + [PromptEntry(id: "new", label: "Ship notes", body: "")]
        XCTAssertEqual(cached(added).prompts.map(\.id), ["ship", "new", "deploy", "old"])
    }
}
