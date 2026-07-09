import XCTest
@testable import Quip

@MainActor
final class PromptLibraryVibeCutTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("quip-vibecut-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        PromptLibrary.directoryOverrideForTests = tmp
    }

    override func tearDown() {
        PromptLibrary.directoryOverrideForTests = nil
        try? FileManager.default.removeItem(at: tmp)
        tmp = nil
        super.tearDown()
    }

    private func write(_ name: String, _ contents: String) {
        try? contents.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: tmp.appendingPathComponent(name).path)
    }

    func testReaderMergesVibeCutPromptPacksWithBaseCatalog() throws {
        let root = tmp.appendingPathComponent("vibecut", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let packs = tmp.appendingPathComponent("VibeCutPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)

        try """
        {
          "version": "3.0",
          "prompts": [
            { "id": "base", "name": "Base Prompt", "prompt": "from repo", "mode": "paste", "type": "text" }
          ]
        }
        """.write(to: shared.appendingPathComponent("prompts.json"), atomically: true, encoding: .utf8)
        try """
        {
          "format": "vibecutpack/1",
          "name": "User Pack",
          "prompts": [
            { "id": "pack", "name": "Pack Prompt", "prompt": "from pack", "mode": "paste", "type": "text" }
          ]
        }
        """.write(to: packs.appendingPathComponent("User Pack.json"), atomically: true, encoding: .utf8)
        try "{ nope".write(to: packs.appendingPathComponent("Broken.json"), atomically: true, encoding: .utf8)

        let catalog = try VibeCutPromptReader(root: root, packsDirectory: packs).read().catalog
        let mapped = VibeCutPromptMapper.map(catalog: catalog)

        XCTAssertEqual(Set(mapped.entries.map(\.label)), ["Base Prompt", "Pack Prompt"])
        XCTAssertEqual(mapped.entries.first { $0.label == "Pack Prompt" }?.body, "from pack")
    }

    func testReaderReportsUndecodablePackFileCount() throws {
        let root = tmp.appendingPathComponent("vibecut", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let packs = tmp.appendingPathComponent("VibeCutPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)

        try """
        { "prompts": [ { "id": "base", "name": "Base", "prompt": "b", "type": "text" } ] }
        """.write(to: shared.appendingPathComponent("prompts.json"), atomically: true, encoding: .utf8)
        try """
        { "format": "vibecutpack/1", "prompts": [ { "id": "p", "name": "Pack", "prompt": "p", "type": "text" } ] }
        """.write(to: packs.appendingPathComponent("Good.json"), atomically: true, encoding: .utf8)
        try "{ nope".write(to: packs.appendingPathComponent("Broken.json"), atomically: true, encoding: .utf8)
        try "also not json".write(to: packs.appendingPathComponent("Worse.json"), atomically: true, encoding: .utf8)
        // Non-.json files are ignored entirely — neither merged nor counted.
        try "notes".write(to: packs.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let result = try VibeCutPromptReader(root: root, packsDirectory: packs).read()

        XCTAssertEqual(result.skippedPacks, 2)
        XCTAssertEqual(Set(result.catalog.prompts.compactMap(\.name)), ["Base", "Pack"])
    }

    func testReaderReportsZeroSkippedPacksWhenPacksDirectoryMissing() throws {
        let root = tmp.appendingPathComponent("vibecut", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try """
        { "prompts": [ { "id": "base", "name": "Base", "prompt": "b", "type": "text" } ] }
        """.write(to: shared.appendingPathComponent("prompts.json"), atomically: true, encoding: .utf8)

        let missing = tmp.appendingPathComponent("no-such-packs", isDirectory: true)
        let result = try VibeCutPromptReader(root: root, packsDirectory: missing).read()

        XCTAssertEqual(result.skippedPacks, 0)
        XCTAssertEqual(result.catalog.prompts.count, 1)
    }

    func testReplaceVibeCutSetOnlyTouchesReservedNamespaceAndBroadcastsOnce() {
        // Pre-existing: a user prompt, the README, and a STALE inherited file.
        write("mine.txt", "# My Prompt\n\nkeep me")
        write("README.txt", "readme body")
        write("vibecut__old.txt", "# Old\n\nstale inherited")

        let lib = PromptLibrary()
        var broadcasts = 0
        lib.onChange = { _ in broadcasts += 1 }

        let entries = [
            PromptEntry(id: "vibecut__alpha", label: "Alpha", body: "a body", tags: ["vibecut", "x"]),
            PromptEntry(id: "vibecut__beta", label: "Beta", body: "b body", tags: ["vibecut"]),
        ]
        let written = lib.replaceVibeCutSet(entries)

        XCTAssertEqual(written, 2)
        // User + README untouched.
        XCTAssertTrue(exists("mine.txt"))
        XCTAssertTrue(exists("README.txt"))
        // Stale inherited removed; fresh set present.
        XCTAssertFalse(exists("vibecut__old.txt"))
        XCTAssertTrue(exists("vibecut__alpha.txt"))
        XCTAssertTrue(exists("vibecut__beta.txt"))
        // Exactly one broadcast for the whole batch (least-flap guarantee).
        XCTAssertEqual(broadcasts, 1)
        // Catalog holds all three prompts, inherited ones tagged.
        XCTAssertEqual(Set(lib.entries.map(\.id)), ["mine", "vibecut__alpha", "vibecut__beta"])
        XCTAssertTrue(lib.entries.first { $0.id == "vibecut__alpha" }?.isInherited == true)
        XCTAssertTrue(lib.entries.first { $0.id == "mine" }?.isInherited == false)
    }

    func testMetaTagRoundTripsThroughRenderAndParse() {
        let lib = PromptLibrary()
        lib.replaceVibeCutSet([
            PromptEntry(id: "vibecut__commit", label: "Commit", body: "Write a commit.",
                        tags: ["vibecut", "git"]),
        ])
        let entry = lib.entries.first { $0.id == "vibecut__commit" }
        XCTAssertEqual(entry?.label, "Commit")
        XCTAssertEqual(entry?.body, "Write a commit.")
        XCTAssertEqual(entry?.tags, ["vibecut", "git"])
    }

    func testResyncReplacesPriorSetCleanly() {
        let lib = PromptLibrary()
        lib.replaceVibeCutSet([
            PromptEntry(id: "vibecut__a", label: "A", body: "1", tags: ["vibecut"]),
            PromptEntry(id: "vibecut__b", label: "B", body: "2", tags: ["vibecut"]),
        ])
        // Second sync drops "b", adds "c".
        let written = lib.replaceVibeCutSet([
            PromptEntry(id: "vibecut__a", label: "A", body: "1new", tags: ["vibecut"]),
            PromptEntry(id: "vibecut__c", label: "C", body: "3", tags: ["vibecut"]),
        ])
        XCTAssertEqual(written, 2)
        XCTAssertTrue(exists("vibecut__a.txt"))
        XCTAssertFalse(exists("vibecut__b.txt"))   // cleanly removed
        XCTAssertTrue(exists("vibecut__c.txt"))
        XCTAssertEqual(lib.entries.first { $0.id == "vibecut__a" }?.body, "1new")
    }
}
