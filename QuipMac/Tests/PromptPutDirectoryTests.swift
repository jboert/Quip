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
}
