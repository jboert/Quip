import XCTest
@testable import Quip

final class VibeCutPromptMapperTests: XCTestCase {

    // MARK: - Decode tolerance

    func testDecodesFullCatalogShape() throws {
        let json = """
        {
          "version": "3.0",
          "preamble": "SHARED PREAMBLE TEXT",
          "categories": { "git": { "order": 6, "label": "Git & Deploy" } },
          "prompts": [
            {
              "id": "14-commit", "slug": "commit", "name": "Commit",
              "category": "git", "tags": ["workflow"], "prompt": "Write a commit.",
              "mode": "paste", "type": "text", "skip_preamble": false
            }
          ]
        }
        """
        let catalog = try JSONDecoder().decode(VibeCutCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.version, "3.0")
        XCTAssertEqual(catalog.preamble, "SHARED PREAMBLE TEXT")
        XCTAssertEqual(catalog.prompts.count, 1)
        XCTAssertEqual(catalog.prompts[0].name, "Commit")
        XCTAssertEqual(catalog.prompts[0].category, "git")
        XCTAssertEqual(catalog.prompts[0].tags, ["workflow"])
    }

    func testDecodesMinimalPromptAndToleratesUnknownFields() throws {
        let json = """
        { "prompts": [ { "name": "Bare", "prompt": "Body", "surprise_field": 99 } ] }
        """
        let catalog = try JSONDecoder().decode(VibeCutCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.prompts.count, 1)
        XCTAssertNil(catalog.prompts[0].mode)
        XCTAssertNil(catalog.prompts[0].type)
        XCTAssertNil(catalog.prompts[0].skipPreamble)
    }

    func testDecodesEmptyCatalog() throws {
        let catalog = try JSONDecoder().decode(VibeCutCatalog.self, from: Data("{}".utf8))
        XCTAssertTrue(catalog.prompts.isEmpty)
    }

    // MARK: - Include filter

    func testFilterKeepsRealTextPromptsOnly() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(name: "Keep Text", prompt: "body", mode: "paste", type: "text"),
            VibeCutPrompt(name: "Keep No Type", prompt: "body", mode: "paste", type: nil),
            VibeCutPrompt(name: "Clear", prompt: "/clear", mode: "send", type: "text"),   // send -> skip
            VibeCutPrompt(name: "Screenshot", prompt: "body", mode: "paste", type: "screenshot"), // non-text -> skip
            VibeCutPrompt(name: "Stats", prompt: "body", mode: "paste", type: "stats"),   // non-text -> skip
            VibeCutPrompt(name: "Empty", prompt: "", mode: "paste", type: "text"),        // empty body -> skip
            VibeCutPrompt(name: "NoBody", prompt: nil, mode: "paste", type: "text"),      // nil body -> skip
        ])
        let result = VibeCutPromptMapper.map(catalog: catalog)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.skipped, 5)
        XCTAssertEqual(Set(result.entries.map(\.label)), ["Keep Text", "Keep No Type"])
    }

    // MARK: - Body: preamble is stripped

    func testBodyIsRawPromptWithoutPreamble() {
        let catalog = VibeCutCatalog(
            preamble: "ARCHITECTURE CONTEXT: big shared block ---",
            prompts: [VibeCutPrompt(name: "Audit", prompt: "Do a security audit.",
                                    mode: "paste", type: "text", skipPreamble: false)]
        )
        let result = VibeCutPromptMapper.map(catalog: catalog)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].body, "Do a security audit.")
        XCTAssertFalse(result.entries[0].body.contains("ARCHITECTURE CONTEXT"))
    }

    // MARK: - Id namespacing + slug + tag

    func testIdNamespaceSlugAndVibecutTag() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(name: "PCI/NACHA Compliance!", category: "security",
                          tags: ["audit"], prompt: "b", mode: "paste", type: "text"),
        ])
        let e = VibeCutPromptMapper.map(catalog: catalog).entries[0]
        XCTAssertEqual(e.id, "vibecut__pci-nacha-compliance")
        XCTAssertEqual(e.label, "PCI/NACHA Compliance!")
        XCTAssertTrue(e.isInherited)
        XCTAssertEqual(e.tags, ["vibecut", "security", "audit"])  // vibecut first, category, then tags, deduped
    }

    func testTagsAreDedupedWhenVibecutAlreadyPresent() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(name: "X", category: "vibecut", tags: ["vibecut", "y"],
                          prompt: "b", mode: "paste", type: "text"),
        ])
        let e = VibeCutPromptMapper.map(catalog: catalog).entries[0]
        XCTAssertEqual(e.tags, ["vibecut", "y"])
    }

    func testEmptySlugFallsBackToUntitled() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(name: "!!!", prompt: "b", mode: "paste", type: "text"),
        ])
        let e = VibeCutPromptMapper.map(catalog: catalog).entries[0]
        XCTAssertEqual(e.id, "vibecut__untitled-1")  // slug empty -> id falls back
        XCTAssertEqual(e.label, "!!!")               // but the real name is preserved as label
    }

    func testTrulyEmptyNameUsesFallbackForBothIdAndLabel() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(name: "", prompt: "b", mode: "paste", type: "text"),
        ])
        let e = VibeCutPromptMapper.map(catalog: catalog).entries[0]
        XCTAssertEqual(e.id, "vibecut__untitled-1")
        XCTAssertEqual(e.label, "untitled-1")
    }

    // MARK: - Collision handling

    func testDuplicateSlugsGetDeterministicSuffixes() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "a", name: "Code Review", prompt: "one", mode: "paste", type: "text"),
            VibeCutPrompt(id: "b", name: "Code Review", prompt: "two", mode: "paste", type: "text"),
            VibeCutPrompt(id: "c", name: "Code Review", prompt: "three", mode: "paste", type: "text"),
        ])
        let ids = VibeCutPromptMapper.map(catalog: catalog).entries.map(\.id)
        XCTAssertEqual(ids, ["vibecut__code-review", "vibecut__code-review-2", "vibecut__code-review-3"])
    }

    // MARK: - Determinism

    func testMapIsDeterministicRegardlessOfInputOrder() {
        let a = VibeCutPrompt(id: "1", name: "Beta", prompt: "b", mode: "paste", type: "text")
        let b = VibeCutPrompt(id: "2", name: "Alpha", prompt: "a", mode: "paste", type: "text")
        let forward = VibeCutPromptMapper.map(catalog: VibeCutCatalog(prompts: [a, b])).entries
        let reverse = VibeCutPromptMapper.map(catalog: VibeCutCatalog(prompts: [b, a])).entries
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.map(\.label), ["Alpha", "Beta"])  // sorted by name
    }

    // MARK: - Real fixture (the actual VibeCut catalog shape)

    func testMapsAgainstRepresentativeFixture() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(name: "Session Rules", category: "session", tags: ["workflow", "setup"],
                          prompt: "Follow these rules…", mode: "paste", type: "text", skipPreamble: true),
            VibeCutPrompt(name: "Clear Context", category: "session", tags: ["session"],
                          prompt: "/clear", mode: "send", type: "text"),
            VibeCutPrompt(name: "Compact", category: "session", prompt: "/compact", mode: "send", type: "text"),
        ])
        let result = VibeCutPromptMapper.map(catalog: catalog)
        XCTAssertEqual(result.entries.count, 1)      // only Session Rules survives (others are send)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(result.entries[0].id, "vibecut__session-rules")
        XCTAssertTrue(result.entries[0].tags?.contains("vibecut") == true)
    }

    // MARK: - US-002: sync wire messages + isInherited

    func testSyncVibeCutMessageRoundTrip() throws {
        let mid = UUID()
        let msg = SyncVibeCutMessage(messageId: mid)
        XCTAssertEqual(msg.type, "sync_vibecut")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncVibeCutMessage.self, from: data)
        XCTAssertEqual(decoded.type, "sync_vibecut")
        XCTAssertEqual(decoded.messageId, mid)
    }

    func testSyncVibeCutAckRoundTrip() throws {
        let mid = UUID()
        let ack = SyncVibeCutAckMessage(messageId: mid, syncedCount: 23, skippedCount: 5)
        XCTAssertEqual(ack.type, "sync_vibecut_ack")
        XCTAssertNil(ack.error)
        let data = try JSONEncoder().encode(ack)
        let decoded = try JSONDecoder().decode(SyncVibeCutAckMessage.self, from: data)
        XCTAssertEqual(decoded.syncedCount, 23)
        XCTAssertEqual(decoded.skippedCount, 5)
        XCTAssertEqual(decoded.messageId, mid)
    }

    func testSyncVibeCutAckCarriesError() throws {
        let ack = SyncVibeCutAckMessage(messageId: UUID(), syncedCount: 0, skippedCount: 0,
                                        error: "VibeCut repo not found at /nope")
        let decoded = try JSONDecoder().decode(SyncVibeCutAckMessage.self,
                                               from: try JSONEncoder().encode(ack))
        XCTAssertEqual(decoded.error, "VibeCut repo not found at /nope")
        XCTAssertEqual(decoded.syncedCount, 0)
    }

    func testIsInheritedFalseForPlainPrompt() {
        let plain = PromptEntry(id: "my-note", label: "My Note", body: "hi")
        XCTAssertFalse(plain.isInherited)
        let tagged = PromptEntry(id: "x", label: "X", body: "hi", tags: ["other"])
        XCTAssertFalse(tagged.isInherited)
        let inherited = PromptEntry(id: "vibecut__x", label: "X", body: "hi", tags: ["vibecut"])
        XCTAssertTrue(inherited.isInherited)
    }
}
