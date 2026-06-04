import XCTest
@testable import Quip

/// Locks PromptLibrary's on-disk format (§6.1): the `<!-- quip:meta -->`
/// front-matter parses, round-trips, and — critically — renders byte-identical
/// to the legacy format when no metadata is set (so existing files don't churn).
final class PromptFrontMatterTests: XCTestCase {

    // MARK: parse

    func test_legacyHeaderless_parsesAsBody() {
        let p = PromptLibrary.parsePrompt(filename: "myid", raw: "just the body\nline two")
        XCTAssertEqual(p.label, "myid")
        XCTAssertEqual(p.body, "just the body\nline two")
        XCTAssertNil(p.tags)
        XCTAssertNil(p.targetAgent)
        XCTAssertNil(p.description)
    }

    func test_labelOnly_unchanged() {
        let p = PromptLibrary.parsePrompt(filename: "id", raw: "# Ship It\n\nship the code")
        XCTAssertEqual(p.label, "Ship It")
        XCTAssertEqual(p.body, "ship the code")
        XCTAssertNil(p.tags)
    }

    func test_metaBlock_parsed() {
        let raw = "# Ship\n<!-- quip:meta\ntags: release, swift\nagent: claude\ndesc: ship it good\n-->\n\nthe body"
        let p = PromptLibrary.parsePrompt(filename: "id", raw: raw)
        XCTAssertEqual(p.label, "Ship")
        XCTAssertEqual(p.body, "the body")
        XCTAssertEqual(p.tags, ["release", "swift"])
        XCTAssertEqual(p.targetAgent, "claude")
        XCTAssertEqual(p.description, "ship it good")
    }

    // MARK: render

    func test_renderFile_noMeta_byteIdenticalToLegacy() {
        // label differs from id → "# label\n\nbody\n" (legacy)
        XCTAssertEqual(
            PromptLibrary.renderFile(id: "id", label: "Title", body: "hi", tags: nil, targetAgent: nil, description: nil),
            "# Title\n\nhi\n")
        // label == id and empty label → bare "body\n" (legacy)
        XCTAssertEqual(
            PromptLibrary.renderFile(id: "id", label: "id", body: "hi", tags: nil, targetAgent: nil, description: nil),
            "hi\n")
        XCTAssertEqual(
            PromptLibrary.renderFile(id: "id", label: "", body: "hi", tags: nil, targetAgent: nil, description: nil),
            "hi\n")
    }

    // MARK: round-trip

    func test_renderThenParse_roundTrip_withLabelAndMeta() {
        let file = PromptLibrary.renderFile(id: "id", label: "Title", body: "multi\nline body",
                                            tags: ["a", "b"], targetAgent: "cursor", description: "d")
        let p = PromptLibrary.parsePrompt(filename: "id", raw: file)
        XCTAssertEqual(p.label, "Title")
        XCTAssertEqual(p.body, "multi\nline body")
        XCTAssertEqual(p.tags, ["a", "b"])
        XCTAssertEqual(p.targetAgent, "cursor")
        XCTAssertEqual(p.description, "d")
    }

    func test_renderThenParse_roundTrip_metaOnlyNoLabel() {
        let file = PromptLibrary.renderFile(id: "id", label: "id", body: "body",
                                            tags: ["x"], targetAgent: nil, description: nil)
        let p = PromptLibrary.parsePrompt(filename: "id", raw: file)
        XCTAssertEqual(p.label, "id")
        XCTAssertEqual(p.body, "body")
        XCTAssertEqual(p.tags, ["x"])
        XCTAssertNil(p.targetAgent)
    }

    // MARK: write-through refresh

    @MainActor
    func test_put_updatesEntriesAndNotifiesSynchronously() throws {
        try withTemporaryPromptDirectory { library, recorder in
            XCTAssertNotNil(library.put(id: "ship it", label: "Ship It", body: "ship the code"))

            XCTAssertEqual(library.entries.map(\.id), ["ship-it"])
            XCTAssertEqual(library.entries.first?.label, "Ship It")
            XCTAssertEqual(library.entries.first?.body, "ship the code")
            XCTAssertEqual(recorder.changes.map { $0.map(\.id) }, [["ship-it"]])
        }
    }

    @MainActor
    func test_delete_updatesEntriesAndNotifiesSynchronously() throws {
        try withTemporaryPromptDirectory { library, recorder in
            XCTAssertNotNil(library.put(id: "ship", label: "Ship", body: "ship the code"))
            recorder.changes.removeAll()

            XCTAssertTrue(library.delete(id: "ship"))

            XCTAssertTrue(library.entries.isEmpty)
            XCTAssertEqual(recorder.changes.map { $0.map(\.id) }, [[]])
        }
    }

    @MainActor
    private func withTemporaryPromptDirectory(
        _ body: (PromptLibrary, ChangeRecorder) throws -> Void
    ) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("PromptLibraryTests-\(UUID().uuidString)",
                                                              isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        PromptLibrary.directoryOverrideForTests = dir
        defer {
            PromptLibrary.directoryOverrideForTests = nil
            try? fm.removeItem(at: dir)
        }

        let library = PromptLibrary()
        let recorder = ChangeRecorder()
        library.onChange = { recorder.changes.append($0) }

        try body(library, recorder)
    }

    @MainActor
    private final class ChangeRecorder {
        var changes: [[PromptEntry]] = []
    }
}
