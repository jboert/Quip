import XCTest
@testable import Quip

/// Regression: `PromptLibrary.put` must create its directory before writing.
/// Saving a prompt into a missing `prompts/` directory (the fresh-install /
/// post-`ditto`-reinstall condition) previously sent
/// `String.write(to:atomically:)` down swift-foundation's atomic temp+rename
/// path, which traps with SIGTRAP instead of throwing — bypassing put's
/// `do/catch` and crashing the whole Mac app, taking every phone connection
/// down with it. (Crash 2026-06-14: put → StringProtocol.write → SIGTRAP.)
final class PromptPutDirectoryTests: XCTestCase {

    @MainActor
    func test_put_intoMissingDirectory_createsAndWrites_noCrash() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quip-pl-\(UUID().uuidString)")
        let promptsDir = root.appendingPathComponent("Quip/prompts", isDirectory: true)
        PromptLibrary.directoryOverrideForTests = promptsDir
        defer {
            PromptLibrary.directoryOverrideForTests = nil
            try? FileManager.default.removeItem(at: root)
        }

        // Precondition: the directory does NOT exist — `start()` (which seeds
        // it) is deliberately not called, mirroring a save that lands before
        // any init created the folder.
        XCTAssertFalse(FileManager.default.fileExists(atPath: promptsDir.path),
                       "precondition: prompts dir absent — the fresh-install crash condition")

        let lib = PromptLibrary()
        let url = lib.put(id: "next", label: "Next",
                          body: "You are Any agent working inside Quip.")

        XCTAssertNotNil(url, "put must create the missing dir and write — not crash, not return nil")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path),
                      "the prompt file must exist on disk after put")
        XCTAssertTrue(try String(contentsOf: url!, encoding: .utf8).contains("You are Any agent"),
                      "the written body must round-trip")
    }

    /// Editing a prompt in the Mac's Settings must keep its tags: an edited
    /// VibeCut project prompt used to lose `project:` and `local-only`.
    @MainActor
    func test_update_keepsTagsAgentAndDescription() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quip-pl-\(UUID().uuidString)")
        PromptLibrary.directoryOverrideForTests = root.appendingPathComponent("prompts", isDirectory: true)
        defer {
            PromptLibrary.directoryOverrideForTests = nil
            try? FileManager.default.removeItem(at: root)
        }
        let lib = PromptLibrary()
        let tags = ["vibecut", "project", "project:Acme", "local-only"]
        XCTAssertNotNil(lib.put(id: "vibecut__proj-1a2b3c4d", label: "Plan", body: "old body",
                                tags: tags, targetAgent: "claude", description: "Plans the day"))
        let original = try XCTUnwrap(lib.entries.first { $0.id == "vibecut__proj-1a2b3c4d" })

        XCTAssertNotNil(lib.update(original, label: "Plan v2", body: "new body"))

        let edited = try XCTUnwrap(lib.entries.first { $0.id == "vibecut__proj-1a2b3c4d" })
        XCTAssertEqual(edited.label, "Plan v2")
        XCTAssertEqual(edited.body, "new body")
        XCTAssertEqual(Set(edited.tags ?? []), Set(tags), "an edit must not drop project: or local-only")
        XCTAssertEqual(edited.targetAgent, "claude")
        XCTAssertEqual(edited.description, "Plans the day")
    }
}
