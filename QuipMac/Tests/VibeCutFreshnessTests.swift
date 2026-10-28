import XCTest
@testable import Quip

/// Q-82: Settings says whether VibeCut changed since the last sync.
@MainActor
final class VibeCutFreshnessTests: XCTestCase {

    private var tmp: URL!
    private var root: URL!
    private var packs: URL!
    private var actions: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("quip-vibecut-fresh-\(UUID().uuidString)", isDirectory: true)
        root = tmp.appendingPathComponent("vibecut", isDirectory: true)
        packs = tmp.appendingPathComponent("packs", isDirectory: true)
        actions = tmp.appendingPathComponent("actions", isDirectory: true)
        for dir in [root.appendingPathComponent("shared"), packs!, actions!] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        write(root.appendingPathComponent("shared/prompts.json"),
              #"{ "prompts": [ { "id": "a", "name": "A", "prompt": "a", "type": "text" } ] }"#)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func write(_ url: URL, _ text: String) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private var reader: VibeCutPromptReader {
        // All four paths: a default privateStoreURL reads the owner's real
        // VibeCut private store (the leak class c5003fe removed elsewhere).
        VibeCutPromptReader(root: root, packsDirectory: packs, actionsDirectory: actions,
                            privateStoreURL: tmp.appendingPathComponent("no-such-private/projects.json"))
    }

    func testFingerprintIsStableWhileNothingChanges() {
        XCTAssertNotNil(reader.sourceFingerprint())
        XCTAssertEqual(reader.sourceFingerprint(), reader.sourceFingerprint())
    }

    func testFingerprintChangesWithEverySourceTheSyncReads() {
        var seen = Set<String>()
        func record() { if let f = reader.sourceFingerprint() { seen.insert(f) } }
        record()
        write(root.appendingPathComponent("shared/prompts.json"),
              #"{ "prompts": [ { "id": "a", "name": "A", "prompt": "b", "type": "text" } ] }"#)
        record()
        write(root.appendingPathComponent("shared/prompt-fragments.json"), #"{ "fragments": {} }"#)
        record()
        write(root.appendingPathComponent("shared/prompt-organization.json"), #"{ "actions": {} }"#)
        record()
        write(packs.appendingPathComponent("P.json"), #"{ "format": "vibecutpack/1", "prompts": [] }"#)
        record()
        write(actions.appendingPathComponent("a.edit.json"), "{}")
        record()
        XCTAssertEqual(seen.count, 6, "each edit should produce a new fingerprint")
    }

    func testFingerprintIgnoresFilesTheSyncDoesNotRead() {
        let before = reader.sourceFingerprint()
        write(packs.appendingPathComponent("notes.txt"), "x")
        write(actions.appendingPathComponent("launch.log"), "x")
        XCTAssertEqual(reader.sourceFingerprint(), before)
    }

    func testNoCatalogMeansNoFingerprint() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("shared/prompts.json"))
        XCTAssertNil(reader.sourceFingerprint())
    }

    func testReadCarriesTheFingerprintItRead() throws {
        XCTAssertEqual(try reader.read().fingerprint, reader.sourceFingerprint())
    }

    func testFreshnessRule() {
        typealias S = VibeCutSyncService
        XCTAssertEqual(S.freshness(syncedFingerprint: "x", currentFingerprint: "x", hasSynced: true), .current)
        XCTAssertEqual(S.freshness(syncedFingerprint: "x", currentFingerprint: "y", hasSynced: true), .changed)
        XCTAssertEqual(S.freshness(syncedFingerprint: nil, currentFingerprint: "y", hasSynced: false), .neverSynced)
        // A sync from before fingerprints were recorded: unknown, never "current".
        XCTAssertEqual(S.freshness(syncedFingerprint: nil, currentFingerprint: "y", hasSynced: true), .unknown)
        XCTAssertEqual(S.freshness(syncedFingerprint: "x", currentFingerprint: nil, hasSynced: true), .unknown)
    }

    // MARK: Wire (Q-85) — through the pure statics, never UserDefaults.standard

    func testWireFreshnessMapsEveryCase() {
        XCTAssertEqual(VibeCutSyncService.wire(.unknown), .unknown)
        XCTAssertEqual(VibeCutSyncService.wire(.neverSynced), .neverSynced)
        XCTAssertEqual(VibeCutSyncService.wire(.current), .current)
        XCTAssertEqual(VibeCutSyncService.wire(.changed), .changed)
        XCTAssertEqual(VibeCutSyncService.wire(.neverSynced).rawValue, "never_synced")
    }

    func testStatusMessageCarriesLastOutcome() {
        let never = VibeCutSyncService.statusMessage(freshness: .neverSynced, lastOutcome: nil)
        XCTAssertEqual(never.wireFreshness, .neverSynced)
        XCTAssertNil(never.lastSyncAt)
        XCTAssertNil(never.syncedCount)
        XCTAssertNil(never.error)

        let when = Date(timeIntervalSince1970: 1_793_150_000)
        let failed = VibeCutSyncService.Outcome(date: when, synced: 0, skipped: 2, skippedPacks: 0,
                                                error: "VibeCut repo not found")
        let failedMsg = VibeCutSyncService.statusMessage(freshness: .unknown, lastOutcome: failed)
        XCTAssertEqual(failedMsg.wireFreshness, .unknown)
        XCTAssertEqual(failedMsg.error, "VibeCut repo not found")
        XCTAssertNil(failedMsg.syncedCount, "a failed attempt landed nothing; no count")
        XCTAssertEqual(failedMsg.lastSyncAt, when.timeIntervalSince1970)

        let good = VibeCutSyncService.Outcome(date: when, synced: 49, skipped: 2, skippedPacks: 1, error: nil)
        let goodMsg = VibeCutSyncService.statusMessage(freshness: .current, lastOutcome: good)
        XCTAssertEqual(goodMsg.wireFreshness, .current)
        XCTAssertEqual(goodMsg.syncedCount, 49)
        XCTAssertEqual(goodMsg.lastSyncAt, when.timeIntervalSince1970)
        XCTAssertNil(goodMsg.error)
    }

    // MARK: Probe timeout (fan-out review, 2026-10-28)

    /// A blocked stat must not hold the caller past the timeout. The first
    /// version used a task group, which waits for every child, so a stat that
    /// never returned made the "timeout" wait forever.
    func testRaceTimeoutReturnsNilWhileTheWorkIsStillBlocked() async {
        let start = Date()
        let result = await VibeCutSyncService.raceTimeout(0.2) { () -> Int in
            Thread.sleep(forTimeInterval: 2)
            return 1
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "the caller waited on the blocked work")
    }

    func testRaceTimeoutReturnsTheWorkWhenItFinishesFirst() async {
        let result = await VibeCutSyncService.raceTimeout(2) { 42 }
        XCTAssertEqual(result, 42)
    }
}
