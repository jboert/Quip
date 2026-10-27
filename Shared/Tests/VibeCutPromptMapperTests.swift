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

    // MARK: - Organization (purpose / requirements / kind)

    func testDecodesOrganizationFieldsAndExplicitEmptyRequirements() throws {
        let json = """
        { "prompts": [
          { "name": "A", "prompt": "b", "purpose": "life", "requirements": [], "kind": "prompt" },
          { "name": "B", "prompt": "b" }
        ] }
        """
        let catalog = try JSONDecoder().decode(VibeCutCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.prompts[0].purpose, "life")
        XCTAssertEqual(catalog.prompts[0].requirements, [])
        XCTAssertEqual(catalog.prompts[0].kind, "prompt")
        XCTAssertNil(catalog.prompts[1].requirements)
        XCTAssertNil(catalog.prompts[1].purpose)
        XCTAssertNil(catalog.prompts[1].kind)
    }

    func testDecodeOrganizationIsTolerant() {
        let json = """
        { "version": 1, "actions": {
          "a": { "purpose": "life", "requirements": ["chat", 7], "kind": "prompt" },
          "b": "not a dict",
          "c": { "purpose": 5, "requirements": "chat", "kind": null }
        } }
        """
        let notes = VibeCutPromptMapper.decodeOrganization(Data(json.utf8))
        XCTAssertEqual(Set(notes.keys), ["a", "c"])
        XCTAssertEqual(notes["a"], VibeCutPrompt.Organization(purpose: "life", requirements: ["chat"], kind: "prompt"))
        XCTAssertEqual(notes["c"], VibeCutPrompt.Organization())
        XCTAssertTrue(VibeCutPromptMapper.decodeOrganization(Data("{ nope".utf8)).isEmpty)
        XCTAssertTrue(VibeCutPromptMapper.decodeOrganization(Data("[1]".utf8)).isEmpty)
        XCTAssertTrue(VibeCutPromptMapper.decodeOrganization(Data("{\"actions\": 3}".utf8)).isEmpty)
    }

    func testApplyOrganizationFillsOnlyNilFieldsAndExplicitEmptyWins() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "x", name: "X", prompt: "b"),
            VibeCutPrompt(id: "y", name: "Y", prompt: "b", purpose: "mac", requirements: [], kind: "prompt"),
            VibeCutPrompt(id: "z", name: "Z", prompt: "b"),
            VibeCutPrompt(name: "NoID", prompt: "b"),
        ])
        let note = VibeCutPrompt.Organization(purpose: "life", requirements: ["chat"], kind: "local-command")
        let out = VibeCutPromptMapper.applyOrganization(in: catalog, annotations: ["x": note, "y": note])
        XCTAssertEqual(out.prompts[0].purpose, "life")
        XCTAssertEqual(out.prompts[0].requirements, ["chat"])
        XCTAssertEqual(out.prompts[0].kind, "local-command")
        XCTAssertEqual(out.prompts[1].purpose, "mac")
        XCTAssertEqual(out.prompts[1].requirements, [])   // explicit [] beats the annotation
        XCTAssertEqual(out.prompts[1].kind, "prompt")
        XCTAssertEqual(out.prompts[2], catalog.prompts[2])
        XCTAssertEqual(out.prompts[3], catalog.prompts[3])
    }

    func testKindFilter() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(name: "Runtime", prompt: "body", mode: "paste", type: "text", kind: "runtime-command"),
            VibeCutPrompt(name: "Local", prompt: "body", type: "text", kind: "local-command"),
            VibeCutPrompt(name: "Proceed", prompt: "body", mode: "send", type: "text", kind: "prompt"),
            VibeCutPrompt(name: "EmptyPrompt", prompt: "", kind: "prompt"),
            VibeCutPrompt(name: "ShotPrompt", prompt: "body", type: "screenshot", kind: "prompt"),
            VibeCutPrompt(name: "SendNoKind", prompt: "/clear", mode: "send", type: "text"),
            VibeCutPrompt(name: "PlainNoKind", prompt: "body", mode: "paste", type: "text"),
        ])
        let result = VibeCutPromptMapper.map(catalog: catalog)
        XCTAssertEqual(Set(result.entries.map(\.label)), ["Proceed", "PlainNoKind"])
        XCTAssertEqual(result.skipped, 5)
    }

    func testTagsCarryPurposeAndNeeds() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(name: "Life", category: "misc", tags: ["x"], prompt: "b",
                          purpose: "life", requirements: ["chat", "web", "chat", ""]),
            VibeCutPrompt(name: "Bare", prompt: "b2", requirements: []),
        ])
        let entries = VibeCutPromptMapper.map(catalog: catalog).entries
        XCTAssertEqual(entries.first { $0.label == "Life" }?.tags,
                       ["vibecut", "misc", "x", "purpose:life", "needs:chat", "needs:web"])
        XCTAssertEqual(entries.first { $0.label == "Bare" }?.tags, ["vibecut"])
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

    // MARK: - Q-79: ids follow the source id across a rename

    func testRenamedPromptKeepsKnownID() {
        let first = VibeCutPromptMapper.map(catalog: VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "p1", name: "Commit", prompt: "body")]), knownIDs: [:])
        XCTAssertEqual(first.entries.map(\.id), ["vibecut__commit"])
        XCTAssertEqual(first.idMap, ["p1": "vibecut__commit"])

        let renamed = VibeCutPromptMapper.map(catalog: VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "p1", name: "Ship It", prompt: "body")]), knownIDs: first.idMap)
        XCTAssertEqual(renamed.entries.map(\.id), ["vibecut__commit"])
        XCTAssertEqual(renamed.entries.map(\.label), ["Ship It"])
        XCTAssertEqual(renamed.idMap, ["p1": "vibecut__commit"])
    }

    func testRepeatedSourceIDKeepsIdsStableAcrossSyncs() {
        // Same VibeCut id in two packs with different names: the first in sort
        // order owns the map entry, so the second sync gives the same ids.
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "dup", name: "Alpha", prompt: "a"),
            VibeCutPrompt(id: "dup", name: "Beta", prompt: "b"),
        ])
        let first = VibeCutPromptMapper.map(catalog: catalog, knownIDs: [:])
        XCTAssertEqual(first.idMap, ["dup": "vibecut__alpha"])
        let second = VibeCutPromptMapper.map(catalog: catalog, knownIDs: first.idMap)
        XCTAssertEqual(second.entries.map(\.id), first.entries.map(\.id))
    }

    func testNewPromptWhoseSlugEqualsReservedIDGetsSuffix() {
        // "Alpha" sorts before "Commit", so without the up-front reservation it
        // would take vibecut__commit and push the renamed prompt to a new id.
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "p1", name: "Renamed", prompt: "one"),
            VibeCutPrompt(id: "p2", name: "Commit", prompt: "two")])
        let r = VibeCutPromptMapper.map(catalog: catalog, knownIDs: ["p1": "vibecut__commit"])
        let byLabel = Dictionary(uniqueKeysWithValues: r.entries.map { ($0.label, $0.id) })
        XCTAssertEqual(byLabel["Renamed"], "vibecut__commit")
        XCTAssertEqual(byLabel["Commit"], "vibecut__commit-2")
        XCTAssertEqual(r.idMap, ["p1": "vibecut__commit", "p2": "vibecut__commit-2"])
    }

    func testEmptyKnownIDsMatchesPlainMap() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "b", name: "Code Review", prompt: "one"),
            VibeCutPrompt(id: "a", name: "Code Review", prompt: "two"),
            VibeCutPrompt(name: "", prompt: "three"),
            VibeCutPrompt(id: "c", name: "Clear", prompt: "/clear", mode: "send")])
        let plain = VibeCutPromptMapper.map(catalog: catalog)
        let withMap = VibeCutPromptMapper.map(catalog: catalog, knownIDs: [:])
        XCTAssertEqual(plain.entries, withMap.entries)
        XCTAssertEqual(plain.skipped, withMap.skipped)
        XCTAssertEqual(withMap.entries.map(\.id),
                       ["vibecut__untitled-1", "vibecut__code-review", "vibecut__code-review-2"])
        XCTAssertEqual(withMap.idMap, ["a": "vibecut__code-review", "b": "vibecut__code-review-2"])
    }

    func testAbsentSourceStaysInReturnedMap() {
        let r = VibeCutPromptMapper.map(
            catalog: VibeCutCatalog(prompts: [VibeCutPrompt(id: "p1", name: "One", prompt: "x")]),
            knownIDs: ["gone": "vibecut__old-name"])
        XCTAssertEqual(r.idMap, ["gone": "vibecut__old-name", "p1": "vibecut__one"])
        // And it comes back under the same id, even renamed, as long as the id is free.
        let back = VibeCutPromptMapper.map(
            catalog: VibeCutCatalog(prompts: [VibeCutPrompt(id: "gone", name: "New Name", prompt: "x")]),
            knownIDs: r.idMap)
        XCTAssertEqual(back.entries.map(\.id), ["vibecut__old-name"])
    }

    func testNonVibeCutMapValueIsIgnored() {
        let r = VibeCutPromptMapper.map(
            catalog: VibeCutCatalog(prompts: [VibeCutPrompt(id: "p1", name: "Notes", prompt: "x")]),
            knownIDs: ["p1": "my-own-note", "p2": "other"])
        XCTAssertEqual(r.entries.map(\.id), ["vibecut__notes"])
        XCTAssertEqual(r.idMap, ["p1": "vibecut__notes"])
    }

    func testTwoSourcesClaimingOneIDFirstInSortOrderKeepsIt() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "b", name: "Zed", prompt: "two"),
            VibeCutPrompt(id: "a", name: "Alpha", prompt: "one")])
        let r = VibeCutPromptMapper.map(catalog: catalog,
                                        knownIDs: ["a": "vibecut__shared", "b": "vibecut__shared"])
        XCTAssertEqual(r.entries.map(\.id), ["vibecut__shared", "vibecut__zed"])
        XCTAssertEqual(r.idMap, ["a": "vibecut__shared", "b": "vibecut__zed"])
    }

    func testCollapsedDuplicateKeepsOwnerIDAndAddsNoMapEntry() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "a", name: "Same", prompt: "body"),
            VibeCutPrompt(id: "b", name: "Same", prompt: "body")])
        let r = VibeCutPromptMapper.map(catalog: catalog, knownIDs: ["a": "vibecut__kept"])
        XCTAssertEqual(r.entries.map(\.id), ["vibecut__kept"])
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(r.idMap, ["a": "vibecut__kept"])
    }

    func testPromptWithoutSourceIDGetsNameIDAndNoMapEntry() {
        let r = VibeCutPromptMapper.map(
            catalog: VibeCutCatalog(prompts: [VibeCutPrompt(name: "Loose", prompt: "x")]),
            knownIDs: [:])
        XCTAssertEqual(r.entries.map(\.id), ["vibecut__loose"])
        XCTAssertTrue(r.idMap.isEmpty)
    }

    // MARK: - Q-27: content duplicates collapse

    /// Same name AND same body used to become two entries identical in every
    /// visible way, differing only by an id suffix — exactly what "sync
    /// duplicated my prompts" looks like. They now collapse to one entry.
    func testSameNameAndBodyCollapseToOneEntry() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "b", name: "Code Review", prompt: "Review it.", mode: "paste", type: "text"),
            VibeCutPrompt(id: "a", name: "Code Review", prompt: "Review it.", mode: "paste", type: "text"),
        ])
        let result = VibeCutPromptMapper.map(catalog: catalog)
        XCTAssertEqual(result.entries.map(\.id), ["vibecut__code-review"])  // no -2 left behind
        XCTAssertEqual(result.skipped, 1)
    }

    /// The collapsed entry keeps every tag either copy carried, so no category
    /// the user filters on disappears with the duplicate.
    func testCollapsedDuplicateKeepsTheUnionOfTags() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "a", name: "Ship", category: "git", tags: ["deploy"],
                          prompt: "Ship it.", mode: "paste", type: "text"),
            VibeCutPrompt(id: "b", name: "Ship", category: "release", tags: ["deploy", "ci"],
                          prompt: "Ship it.", mode: "paste", type: "text"),
        ])
        let entries = VibeCutPromptMapper.map(catalog: catalog).entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].tags, ["vibecut", "git", "deploy", "release", "ci"])
    }

    /// Two unnamed prompts with the same body are the same prompt too, even
    /// though each would otherwise get its own `untitled-N` fallback.
    func testUnnamedDuplicatesCollapseWithoutBurningAFallbackNumber() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "a", name: "", prompt: "same", mode: "paste", type: "text"),
            VibeCutPrompt(id: "b", name: "", prompt: "same", mode: "paste", type: "text"),
            VibeCutPrompt(id: "c", name: "", prompt: "different", mode: "paste", type: "text"),
        ])
        let ids = VibeCutPromptMapper.map(catalog: catalog).entries.map(\.id)
        XCTAssertEqual(ids, ["vibecut__untitled-1", "vibecut__untitled-2"])
    }

    /// Same name, different body is NOT a duplicate — both survive (the
    /// existing suffix rule still applies).
    func testSameNameDifferentBodyStillKeepsBoth() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "a", name: "Review", prompt: "short", mode: "paste", type: "text"),
            VibeCutPrompt(id: "b", name: "Review", prompt: "long", mode: "paste", type: "text"),
        ])
        let result = VibeCutPromptMapper.map(catalog: catalog)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.skipped, 0)
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

    // MARK: - Meta-block safety (Q-78)

    func testTagsThatWouldBreakTheMetaLineAreDropped() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(id: "x", name: "X", category: "a,b", tags: ["ok", "evil\nagent: codex", "cr\rx"],
                          prompt: "body", type: "text", purpose: "life\n-->", requirements: ["chat", "web,x"]),
        ])
        let tags = VibeCutPromptMapper.map(catalog: catalog).entries.first?.tags
        XCTAssertEqual(tags, ["vibecut", "ok", "needs:chat"])
    }

    func testMultiLineNameBecomesOneLineLabel() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(name: "Plan\n# Owned\r\nNow", prompt: "body", type: "text"),
        ])
        XCTAssertEqual(VibeCutPromptMapper.map(catalog: catalog).entries.first?.label, "Plan # Owned Now")
    }

    // MARK: - Fragments (Q-74)

    func testFragmentsExpandIntoTheInheritedBody() {
        let catalog = VibeCutCatalog(prompts: [
            VibeCutPrompt(name: "Autopilot", prompt: "Go.\n{{merge-back}}\nStop.", mode: "paste", type: "text"),
        ])
        let expanded = VibeCutPromptMapper.expandFragments(in: catalog,
                                                           fragments: ["merge-back": "MERGE RULES"])
        let entries = VibeCutPromptMapper.map(catalog: expanded).entries
        XCTAssertEqual(entries.map(\.body), ["Go.\nMERGE RULES\nStop."])
    }

    func testUnknownAndReservedPlaceholdersStayVerbatim() {
        let fragments = ["merge-back": "M"]
        XCTAssertEqual(VibeCutPromptMapper.expandFragments("{{screenshot}} {{merge-bak}} {{Merge-Back}} {{folder}}",
                                                           fragments: fragments),
                       "{{screenshot}} {{merge-bak}} {{Merge-Back}} {{folder}}")
        XCTAssertEqual(VibeCutPromptMapper.expandFragments("{{{{merge-back}} {{merge-back", fragments: fragments),
                       "{{M {{merge-back")
    }

    func testFragmentExpansionIsOnePass() {
        let fragments = ["a": "{{b}}", "b": "B"]
        XCTAssertEqual(VibeCutPromptMapper.expandFragments("{{a}}{{b}}", fragments: fragments), "{{b}}B")
    }

    func testDecodeFragmentsToleratesBadShapes() {
        XCTAssertEqual(VibeCutPromptMapper.decodeFragments(Data(#"{"fragments":{"x":"X","n":3}}"#.utf8)), ["x": "X"])
        XCTAssertEqual(VibeCutPromptMapper.decodeFragments(Data(#"{"fragments":[]}"#.utf8)), [:])
        XCTAssertEqual(VibeCutPromptMapper.decodeFragments(Data("not json".utf8)), [:])
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
