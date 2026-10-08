import XCTest
@testable import Quip

/// PRD broadcast-and-search US-112: broadcasting a library prompt counts
/// toward its ranking, once per agent among the target windows.
final class BroadcastUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Each context's score at `now`, which is its use count when every use
    /// happened at `now`.
    private func contextScores(_ record: PromptUsageRecord) -> [String: Double] {
        record.contexts.mapValues { $0.value(at: now, halfLife: PromptRanker.halfLife) }
    }

    func test_aBroadcastToClaudeAndCodexWindowsRaisesThePromptForBoth() throws {
        let store = BroadcastUsage.recording("ship", contexts: ["claude", "claude", "codex"], at: now, in: [:])
        let record = try XCTUnwrap(store["ship"])
        XCTAssertEqual(record.uses, 2)
        XCTAssertEqual(contextScores(record), ["claude": 1, "codex": 1])
        let elsewhere = PromptRanker.score(record, context: "shell", at: now)
        XCTAssertGreaterThan(PromptRanker.score(record, context: "claude", at: now), elsewhere)
        XCTAssertGreaterThan(PromptRanker.score(record, context: "codex", at: now), elsewhere)
    }

    func test_manyWindowsOfOneAgentCountOnce() throws {
        let store = BroadcastUsage.recording("ship", contexts: [String?](repeating: "claude", count: 4),
                                             at: now, in: [:])
        let record = try XCTUnwrap(store["ship"])
        XCTAssertEqual(record.uses, 1)
        XCTAssertEqual(contextScores(record), ["claude": 1])
    }

    func test_targetsWithNoAgentCountOnceWithoutAContext() throws {
        let store = BroadcastUsage.recording("ship", contexts: [nil, "", nil], at: now, in: [:])
        let record = try XCTUnwrap(store["ship"])
        XCTAssertEqual(record.uses, 1)
        XCTAssertEqual(record.contexts, [:])
    }

    func test_onlyTargetsWithAnAgentCountWhenSomeHaveOne() throws {
        let store = BroadcastUsage.recording("ship", contexts: [nil, "codex", ""], at: now, in: [:])
        let record = try XCTUnwrap(store["ship"])
        XCTAssertEqual(record.uses, 1)
        XCTAssertEqual(contextScores(record), ["codex": 1])
    }

    func test_aBroadcastAddsToThePromptsHistory() throws {
        let before = PromptRanker.recording("ship", context: "claude", at: now, in: [:])
        let store = BroadcastUsage.recording("ship", contexts: ["codex", "claude"], at: now, in: before)
        let record = try XCTUnwrap(store["ship"])
        XCTAssertEqual(record.uses, 3)
        XCTAssertEqual(contextScores(record), ["claude": 2, "codex": 1])
    }

    func test_aBroadcastWithNoTargetsLeavesTheStoreUnchanged() {
        let store = PromptRanker.recording("ship", context: "claude", at: now, in: [:])
        XCTAssertEqual(BroadcastUsage.recording("ship", contexts: [], at: now, in: store), store)
        XCTAssertEqual(BroadcastUsage.recording("ship", contexts: [], at: now, in: [:]), [:])
    }
}
