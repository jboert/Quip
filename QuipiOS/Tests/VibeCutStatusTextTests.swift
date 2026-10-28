import XCTest
@testable import Quip

/// Q-85: the Prompts hub's one VibeCut status line, rule by rule.
final class VibeCutStatusTextTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_793_160_000)

    func testAFailedLastAttemptWinsOverAnyFreshness() {
        let line = VibeCutStatusText.line(freshness: .current, lastSyncAt: now, syncedCount: 3,
                                          error: "VibeCut repo not found", now: now)
        XCTAssertEqual(line, .init(text: "Last sync failed — VibeCut repo not found", tone: .failed))
    }

    func testNeverSynced() {
        let line = VibeCutStatusText.line(freshness: .neverSynced, lastSyncAt: nil, syncedCount: nil,
                                          error: nil, now: now)
        XCTAssertEqual(line, .init(text: "Never synced from VibeCut", tone: .neutral))
    }

    func testChangedIsDueAndNamesTheAction() {
        let line = VibeCutStatusText.line(freshness: .changed, lastSyncAt: now.addingTimeInterval(-3600),
                                          syncedCount: 49, error: nil, now: now)
        XCTAssertEqual(line, .init(text: "VibeCut changed since the last sync — Sync", tone: .due))
    }

    func testCurrentShowsCountAndRelativeTime() {
        let line = VibeCutStatusText.line(freshness: .current, lastSyncAt: now.addingTimeInterval(-7200),
                                          syncedCount: 49, error: nil, now: now)
        XCTAssertEqual(line?.tone, .neutral)
        XCTAssertEqual(line?.text, "Up to date with VibeCut · 49 prompts · 2 hours ago")
    }

    func testCurrentWithoutACountOmitsIt() {
        let line = VibeCutStatusText.line(freshness: .current, lastSyncAt: now.addingTimeInterval(-10),
                                          syncedCount: nil, error: nil, now: now)
        XCTAssertEqual(line?.text, "Up to date with VibeCut · just now")
    }

    func testOnePromptIsSingular() {
        let line = VibeCutStatusText.line(freshness: .current, lastSyncAt: nil,
                                          syncedCount: 1, error: nil, now: now)
        XCTAssertEqual(line?.text, "Up to date with VibeCut · 1 prompt")
    }

    func testUnknownFreshnessShowsNothing() {
        XCTAssertNil(VibeCutStatusText.line(freshness: .unknown, lastSyncAt: now, syncedCount: 3,
                                            error: nil, now: now))
    }

    func testFutureFreshnessValueReadsUnknown() {
        XCTAssertNil(VibeCutFreshnessWire(rawValue: "stale"))
        XCTAssertEqual(VibeCutFreshnessWire(rawValue: "stale") ?? .unknown, .unknown)
    }
}
