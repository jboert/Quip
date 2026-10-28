import XCTest
import CryptoKit
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

    func testReaderExpandsFragmentsInCatalogAndPackBodies() throws {
        let root = tmp.appendingPathComponent("vibecut", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let packs = tmp.appendingPathComponent("VibeCutPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        try """
        { "prompts": [ { "id": "base", "name": "Base", "prompt": "a {{merge-back}} b", "type": "text" } ] }
        """.write(to: shared.appendingPathComponent("prompts.json"), atomically: true, encoding: .utf8)
        try """
        { "fragments": { "merge-back": "RULES" } }
        """.write(to: shared.appendingPathComponent("prompt-fragments.json"), atomically: true, encoding: .utf8)
        try """
        { "format": "vibecutpack/1", "prompts": [ { "id": "p", "name": "Pack", "prompt": "{{merge-back}}", "type": "text" } ] }
        """.write(to: packs.appendingPathComponent("Good.json"), atomically: true, encoding: .utf8)

        let catalog = try VibeCutPromptReader(root: root, packsDirectory: packs).read().catalog

        XCTAssertEqual(catalog.prompts.compactMap(\.prompt), ["a RULES b", "RULES"])
    }

    func testReaderUsesTheVibeCutEditorsSavedText() throws {
        let root = tmp.appendingPathComponent("vibecut", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let actions = tmp.appendingPathComponent("VibeCutActions", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actions, withIntermediateDirectories: true)
        try """
        { "prompts": [ { "id": "65-proceed", "name": "Proceed", "prompt": "catalog body", "mode": "send", "type": "text" } ] }
        """.write(to: shared.appendingPathComponent("prompts.json"), atomically: true, encoding: .utf8)
        let script = Data("compiled".utf8)
        try script.write(to: actions.appendingPathComponent("65-proceed.scpt"))
        let hash = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        try """
        { "id": "65-proceed", "prompt": "edited body", "mode": "paste", "type": "text",
          "skipPreamble": true, "screenshotPrefix": "65-proceed", "scriptSHA256": "\(hash)" }
        """.write(to: actions.appendingPathComponent("65-proceed.edit.json"), atomically: true, encoding: .utf8)

        let missing = tmp.appendingPathComponent("no-such-packs", isDirectory: true)
        let catalog = try VibeCutPromptReader(root: root, packsDirectory: missing,
                                              actionsDirectory: actions).read().catalog

        XCTAssertEqual(catalog.prompts.first?.prompt, "edited body")
        XCTAssertEqual(catalog.prompts.first?.mode, "paste")
    }

    func testReaderWithoutFragmentsFileLeavesPlaceholders() throws {
        let root = tmp.appendingPathComponent("vibecut", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try """
        { "prompts": [ { "id": "base", "name": "Base", "prompt": "a {{merge-back}}", "type": "text" } ] }
        """.write(to: shared.appendingPathComponent("prompts.json"), atomically: true, encoding: .utf8)

        let missing = tmp.appendingPathComponent("no-such-packs", isDirectory: true)
        let catalog = try VibeCutPromptReader(root: root, packsDirectory: missing).read().catalog

        XCTAssertEqual(catalog.prompts.compactMap(\.prompt), ["a {{merge-back}}"])
    }

    func testReaderAppliesOrganizationAnnotationsToTags() throws {
        let root = tmp.appendingPathComponent("vibecut", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try """
        { "prompts": [
          { "id": "life-1", "name": "Life Prompt", "prompt": "b", "type": "text" },
          { "id": "cmd-1", "name": "Cmd", "prompt": "b", "type": "text" }
        ] }
        """.write(to: shared.appendingPathComponent("prompts.json"), atomically: true, encoding: .utf8)
        try """
        { "version": 1, "actions": {
          "life-1": { "purpose": "life", "requirements": ["chat"], "kind": "prompt" },
          "cmd-1": { "purpose": "mac", "requirements": [], "kind": "local-command" }
        } }
        """.write(to: shared.appendingPathComponent("prompt-organization.json"), atomically: true, encoding: .utf8)

        let missing = tmp.appendingPathComponent("no-such-packs", isDirectory: true)
        let catalog = try VibeCutPromptReader(root: root, packsDirectory: missing).read().catalog
        let mapped = VibeCutPromptMapper.map(catalog: catalog)

        XCTAssertEqual(mapped.entries.map(\.label), ["Life Prompt"])   // local-command skipped
        XCTAssertTrue(mapped.entries[0].tags?.contains("purpose:life") == true)
        XCTAssertTrue(mapped.entries[0].tags?.contains("needs:chat") == true)
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

    // MARK: Unsupported schema (Q-81)

    private func makeCatalogRoot(version: String?) throws -> URL {
        let root = tmp.appendingPathComponent("vibecut", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let versionLine = version.map { "\"version\": \"\($0)\"," } ?? ""
        try """
        { \(versionLine) "prompts": [ { "id": "base", "name": "Base", "prompt": "b", "type": "text" } ] }
        """.write(to: shared.appendingPathComponent("prompts.json"), atomically: true, encoding: .utf8)
        return root
    }

    private func readNoPacks(root: URL) throws -> VibeCutPromptReader.ReadResult {
        let missing = tmp.appendingPathComponent("no-such-packs", isDirectory: true)
        return try VibeCutPromptReader(root: root, packsDirectory: missing).read()
    }

    func testReaderRefusesCatalogVersionNewerThanSupported() throws {
        let root = try makeCatalogRoot(version: "4.0")
        XCTAssertThrowsError(try readNoPacks(root: root)) { error in
            guard case VibeCutPromptReader.ReadError.unsupportedVersion(let v) = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(v, "4.0")
            XCTAssertEqual((error as? VibeCutPromptReader.ReadError)?.description,
                           "VibeCut catalog version 4.0 is newer than this Quip understands")
        }
    }

    func testReaderAcceptsMinorBumpAndMissingVersion() throws {
        XCTAssertEqual(try readNoPacks(root: makeCatalogRoot(version: "3.1")).catalog.prompts.count, 1)
        XCTAssertEqual(try readNoPacks(root: makeCatalogRoot(version: nil)).catalog.prompts.count, 1)
    }

    func testReaderRefusesUnparseableCatalogVersion() throws {
        let root = try makeCatalogRoot(version: "abc")
        XCTAssertThrowsError(try readNoPacks(root: root)) { error in
            guard case VibeCutPromptReader.ReadError.unsupportedVersion = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
        }
    }

    func testReaderCountsPacksWithWrongOrMissingFormatAsSkipped() throws {
        let root = try makeCatalogRoot(version: "3.0")
        let packs = tmp.appendingPathComponent("VibeCutPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        try """
        { "format": "vibecutpack/1", "prompts": [ { "id": "ok", "name": "Ok Pack", "prompt": "p", "type": "text" } ] }
        """.write(to: packs.appendingPathComponent("Good.json"), atomically: true, encoding: .utf8)
        try """
        { "format": "vibecutpack/2", "prompts": [ { "id": "v2", "name": "V2 Pack", "prompt": "p", "type": "text" } ] }
        """.write(to: packs.appendingPathComponent("V2.json"), atomically: true, encoding: .utf8)
        try """
        { "prompts": [ { "id": "nf", "name": "No Format Pack", "prompt": "p", "type": "text" } ] }
        """.write(to: packs.appendingPathComponent("NoFormat.json"), atomically: true, encoding: .utf8)

        let result = try VibeCutPromptReader(root: root, packsDirectory: packs).read()

        XCTAssertEqual(result.skippedPacks, 2)
        XCTAssertEqual(Set(result.catalog.prompts.compactMap(\.name)), ["Base", "Ok Pack"])
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
        let written = try! lib.replaceVibeCutSet(entries)

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
        try! lib.replaceVibeCutSet([
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
        try! lib.replaceVibeCutSet([
            PromptEntry(id: "vibecut__a", label: "A", body: "1", tags: ["vibecut"]),
            PromptEntry(id: "vibecut__b", label: "B", body: "2", tags: ["vibecut"]),
        ])
        // Second sync drops "b", adds "c".
        let written = try! lib.replaceVibeCutSet([
            PromptEntry(id: "vibecut__a", label: "A", body: "1new", tags: ["vibecut"]),
            PromptEntry(id: "vibecut__c", label: "C", body: "3", tags: ["vibecut"]),
        ])
        XCTAssertEqual(written, 2)
        XCTAssertTrue(exists("vibecut__a.txt"))
        XCTAssertFalse(exists("vibecut__b.txt"))   // cleanly removed
        XCTAssertTrue(exists("vibecut__c.txt"))
        XCTAssertEqual(lib.entries.first { $0.id == "vibecut__a" }?.body, "1new")
    }

    func testResyncKeepsProjectsSetOnThePhone() {
        let lib = PromptLibrary()
        try! lib.replaceVibeCutSet([
            PromptEntry(id: "vibecut__a", label: "A", body: "1", tags: ["vibecut"]),
            PromptEntry(id: "vibecut__b", label: "B", body: "2", tags: ["vibecut"]),
        ])
        // The phone sets a project on "a" (put_prompt writes the same file).
        _ = lib.put(id: "vibecut__a", label: "A", body: "1", tags: ["vibecut", "project:Quip"])

        try! lib.replaceVibeCutSet([
            PromptEntry(id: "vibecut__a", label: "A", body: "1new", tags: ["vibecut", "git"]),
            PromptEntry(id: "vibecut__b", label: "B", body: "2", tags: ["vibecut"]),
        ])
        let a = lib.entries.first { $0.id == "vibecut__a" }
        XCTAssertEqual(a?.body, "1new")
        XCTAssertEqual(a?.tags, ["vibecut", "git", "project:Quip"])
        XCTAssertEqual(lib.entries.first { $0.id == "vibecut__b" }?.tags, ["vibecut"])
    }

    func testProjectTagsMergeWithoutDuplicates() {
        XCTAssertEqual(PromptLibrary.projectTags(in: ["vibecut", "Project:Quip", "git"]), ["Project:Quip"])
        // VibeCut-supplied project tags win over the hand-added ones.
        XCTAssertEqual(PromptLibrary.tags(["vibecut", "project:quip"], keepingProjects: ["project:Quip", "project:Web"]),
                       ["vibecut", "project:quip"])
        XCTAssertNil(PromptLibrary.tags(nil, keepingProjects: []))
        XCTAssertEqual(PromptLibrary.tags(nil, keepingProjects: ["project:Quip"]), ["project:Quip"])
    }
}
