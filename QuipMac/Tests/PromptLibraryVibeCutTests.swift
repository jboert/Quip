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
