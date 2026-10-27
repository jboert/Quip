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
        VibeCutPromptReader(root: root, packsDirectory: packs, actionsDirectory: actions)
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
}
