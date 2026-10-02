import XCTest
@testable import Quip

final class PromptRankerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func entry(_ id: String, label: String? = nil) -> PromptEntry {
        PromptEntry(id: id, label: label ?? id, body: "b")
    }

    private func record(_ store: PromptRanker.Store, _ id: String, context: String? = nil,
                        times: Int, at date: Date) -> PromptRanker.Store {
        var s = store
        for _ in 0..<times { s = PromptRanker.recording(id, context: context, at: date, in: s) }
        return s
    }

    private func ids(_ prompts: [PromptEntry], _ store: PromptRanker.Store,
                     context: String? = nil, at now: Date) -> [String] {
        PromptRanker.ranked(prompts, store: store, context: context, at: now).map(\.id)
    }

    // The bug this replaces: last-use order put one stray tap above a prompt
    // used every day.
    func testFrequentPromptOutranksOneStrayRecentTap() {
        var store = record([:], "daily", times: 10, at: t0)
        store = record(store, "stray", times: 1, at: t0.addingTimeInterval(3600))
        let order = ids([entry("stray"), entry("daily")], store, at: t0.addingTimeInterval(3600))
        XCTAssertEqual(order, ["daily", "stray"])
    }

    func testOldHabitFadesBehindCurrentOne() {
        // 4 uses two months ago (~8 half-lives) vs 2 uses today.
        var store = record([:], "old", times: 4, at: t0)
        let now = t0.addingTimeInterval(60 * day)
        store = record(store, "new", times: 2, at: now)
        XCTAssertEqual(ids([entry("old"), entry("new")], store, at: now), ["new", "old"])
    }

    func testDecayHalvesOverOneHalfLife() {
        let s = DecayedScore(value: 8, at: t0)
        XCTAssertEqual(s.value(at: t0.addingTimeInterval(PromptRanker.halfLife), halfLife: PromptRanker.halfLife),
                       4, accuracy: 1e-9)
        // A clock that moved backwards never inflates a score.
        XCTAssertEqual(s.value(at: t0.addingTimeInterval(-day), halfLife: PromptRanker.halfLife), 8)
    }

    func testContextLiftsPromptUsedInThatAgent() {
        var store = record([:], "general", context: "shell", times: 3, at: t0)
        store = record(store, "claudeOnly", context: "claude", times: 2, at: t0)
        let prompts = [entry("general"), entry("claudeOnly")]
        // In a Claude window, 2 + 2×2 = 6 beats 3.
        XCTAssertEqual(ids(prompts, store, context: "claude", at: t0), ["claudeOnly", "general"])
        // Elsewhere the global count decides.
        XCTAssertEqual(ids(prompts, store, context: "codex", at: t0), ["general", "claudeOnly"])
        XCTAssertEqual(ids(prompts, store, context: nil, at: t0), ["general", "claudeOnly"])
    }

    func testUnusedPromptsFollowUsedOnesAlphabetically() {
        let store = record([:], "zeta", times: 1, at: t0)
        let prompts = [entry("b", label: "beta"), entry("zeta"), entry("a", label: "Alpha")]
        XCTAssertEqual(ids(prompts, store, at: t0), ["zeta", "a", "b"])
    }

    func testEqualScoresBreakByRecencyThenId() {
        var store = record([:], "x", times: 1, at: t0)
        store = record(store, "y", times: 1, at: t0)
        XCTAssertEqual(ids([entry("y"), entry("x")], store, at: t0), ["x", "y"])
    }

    func testLegacyMRUMigratesPreservingOrder() {
        let json = #"{"a":"2027-01-01T00:00:00Z","b":"2027-01-03T00:00:00Z","bad":"nope"}"#
        let store = PromptRanker.migrate(legacyMRUJSON: json)
        XCTAssertEqual(Set(store.keys), ["a", "b"])
        XCTAssertEqual(store["a"]?.uses, 1)
        let now = ISO8601DateFormatter().date(from: "2027-01-04T00:00:00Z")!
        XCTAssertEqual(ids([entry("a"), entry("b")], store, at: now), ["b", "a"])
        XCTAssertEqual(PromptRanker.migrate(legacyMRUJSON: "garbage"), [:])
    }

    func testEncodeDecodeRoundTrip() {
        let store = record([:], "a", context: "claude", times: 2, at: t0)
        XCTAssertEqual(PromptRanker.decode(PromptRanker.encode(store)), store)
        XCTAssertEqual(PromptRanker.decode("not json"), [:])
    }

    func testMergeKeepsTheRecordWithMoreUsesAndAddsMissing() {
        let local = record([:], "a", times: 3, at: t0)
        var backup = record([:], "a", times: 1, at: t0)
        backup = record(backup, "b", times: 2, at: t0)
        let merged = PromptRanker.merged(local, with: backup, at: t0)
        XCTAssertEqual(merged["a"]?.uses, 3)  // local was newer — not clobbered
        XCTAssertEqual(merged["b"]?.uses, 2)  // restored from backup
        // Restoring the same backup twice changes nothing.
        XCTAssertEqual(PromptRanker.merged(merged, with: backup, at: t0), merged)
    }

    func testUsageRidesThePreferencesSnapshot() throws {
        let json = PromptRanker.encode(record([:], "a", context: "claude", times: 2, at: t0))
        let blob = try JSONEncoder().encode(PreferencesSnapshot(promptUsageJSON: json))
        let back = try JSONDecoder().decode(PreferencesSnapshot.self, from: blob)
        XCTAssertEqual(back.promptUsageJSON, json)
        // A backup written before the field existed still decodes, as nil.
        let old = try JSONDecoder().decode(PreferencesSnapshot.self, from: Data(#"{"ttsEnabled":true}"#.utf8))
        XCTAssertNil(old.promptUsageJSON)
        XCTAssertEqual(old.ttsEnabled, true)
    }

    func testStoreIsCapped() {
        var store: PromptRanker.Store = [:]
        for i in 0..<(PromptRanker.maxRecords + 5) {
            store = PromptRanker.recording("p\(i)", context: nil, at: t0.addingTimeInterval(Double(i)), in: store)
        }
        XCTAssertEqual(store.count, PromptRanker.maxRecords)
        XCTAssertNil(store["p0"])  // the faintest go first
        XCTAssertNotNil(store["p\(PromptRanker.maxRecords + 4)"])
    }
}
