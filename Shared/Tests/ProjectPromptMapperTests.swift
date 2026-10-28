import XCTest
@testable import Quip

/// Project prompts: `projects` -> `project:` + `local-only` tags, and the
/// privacy helpers built on that tag. Project names here are invented.
final class ProjectPromptMapperTests: XCTestCase {

    private func map(_ prompts: [VibeCutPrompt]) -> [PromptEntry] {
        VibeCutPromptMapper.map(catalog: VibeCutCatalog(version: "3.0", prompts: prompts)).entries
    }

    func testProjectsDecodeFromJSON() throws {
        let json = #"{"version":"3.0","prompts":[{"id":"a","name":"A","prompt":"x","projects":["demo-proj"]}]}"#
        let catalog = try JSONDecoder().decode(VibeCutCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.prompts.first?.projects, ["demo-proj"])
    }

    func testProjectsEmitProjectAndLocalOnlyTags() {
        let e = map([VibeCutPrompt(id: "a", name: "Update draft", prompt: "body",
                                   projects: ["demo-proj", "demo-two"])])
        let tags = e[0].tags ?? []
        XCTAssertTrue(tags.contains("project:demo-proj"))
        XCTAssertTrue(tags.contains("project:demo-two"))
        XCTAssertTrue(tags.contains("local-only"))
        XCTAssertTrue(PromptPrivacy.isLocalOnly(e[0]))
    }

    func testPromptWithoutProjectsIsNotLocalOnly() {
        let e = map([VibeCutPrompt(id: "a", name: "Plain", prompt: "body", projects: [])])
        XCTAssertFalse((e[0].tags ?? []).contains("local-only"))
        XCTAssertFalse((e[0].tags ?? []).contains { $0.hasPrefix("project:") })
        XCTAssertFalse(PromptPrivacy.isLocalOnly(e[0]))
    }

    func testProjectNameWithCommaOrNewlineIsDroppedButStillLocalOnly() {
        let e = map([VibeCutPrompt(id: "a", name: "A", prompt: "body",
                                   projects: ["bad,name", "bad\nname", "demo-proj"])])
        let tags = e[0].tags ?? []
        XCTAssertEqual(tags.filter { $0.hasPrefix("project:") }, ["project:demo-proj"])
        XCTAssertTrue(tags.contains("local-only"))
    }

    func testPrivateStorePromptIsLocalOnlyEvenWithNoProjectsAndKeepsSendMode() {
        let e = map([VibeCutPrompt(id: "proj-1a2b3c4d", name: "Update email draft", category: "project",
                                   prompt: "body", mode: "send", type: "text",
                                   projects: [], fromPrivateStore: true)])
        XCTAssertEqual(e.count, 1, "a send-mode project prompt must still inherit")
        XCTAssertTrue(PromptPrivacy.isLocalOnly(e[0]))
    }

    func testPrivateStorePromptIdDoesNotContainItsName() {
        let e = map([VibeCutPrompt(id: "proj-1a2b3c4d", name: "Update email draft",
                                   prompt: "body", projects: ["demo-proj"], fromPrivateStore: true)])
        XCTAssertEqual(e[0].id, "vibecut__proj-1a2b3c4d")
        XCTAssertFalse(e[0].id.contains("email"))
    }

    func testPublicPromptIdStillFollowsItsName() {
        let e = map([VibeCutPrompt(id: "14-commit", name: "Commit", prompt: "body")])
        XCTAssertEqual(e[0].id, "vibecut__commit")
    }

    func testAJSONFileCannotMarkItselfAsFromThePrivateStore() throws {
        let json = #"{"prompts":[{"id":"a","name":"A","prompt":"x","fromPrivateStore":true}]}"#
        let catalog = try JSONDecoder().decode(VibeCutCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.prompts.first?.fromPrivateStore, false)
    }

    func testStrippingLocalOnlyKeepsEverythingElse() {
        let keep = PromptEntry(id: "vibecut__commit", label: "Commit", body: "b", tags: ["vibecut"])
        let drop = PromptEntry(id: "vibecut__proj-1", label: "P", body: "b",
                               tags: ["vibecut", "project:demo-proj", "LOCAL-ONLY"])
        XCTAssertEqual(PromptPrivacy.strippingLocalOnly([keep, drop]), [keep])
        XCTAssertEqual(PromptPrivacy.localOnlyIDs([keep, drop]), ["vibecut__proj-1"])
    }
}
