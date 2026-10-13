import XCTest
@testable import Quip

/// Prompts that only show in the selector for their projects (Q-69).
final class PromptProjectsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let everywhere = PromptEntry(id: "ship", label: "Ship it", body: "run tests")
    private let api = PromptEntry(id: "migrate", label: "Run migrations", body: "db migrate",
                                  tags: ["db", "project:orchard-api"])
    private let web = PromptEntry(id: "storybook", label: "Storybook", body: "npm run storybook",
                                  tags: ["project:lantern-web", "project:Design-System"])

    func test_projectsComeFromProjectTagsOnly() {
        XCTAssertEqual(PromptProjects.projects(of: api), ["orchard-api"])
        XCTAssertEqual(PromptProjects.projects(of: web), ["lantern-web", "Design-System"])
        XCTAssertEqual(PromptProjects.projects(of: everywhere), [])
        XCTAssertEqual(PromptProjects.projects(inTags: ["project:", "Project: spaced "]), ["spaced"])
    }

    func test_aPromptWithNoProjectBelongsEverywhereOthersOnlyToTheirFolder() {
        XCTAssertTrue(PromptProjects.belongs(everywhere, to: nil))
        XCTAssertTrue(PromptProjects.belongs(everywhere, to: "anything"))
        XCTAssertTrue(PromptProjects.belongs(api, to: "orchard-api"))
        XCTAssertTrue(PromptProjects.belongs(web, to: "design-system"), "folder case does not matter")
        XCTAssertFalse(PromptProjects.belongs(api, to: "lantern-web"))
        XCTAssertFalse(PromptProjects.belongs(api, to: nil), "no folder selected: scoped prompts stay out")
        XCTAssertFalse(PromptProjects.belongs(api, to: "  "))
    }

    func test_settingProjectsKeepsOtherTagsAndCleansNames() {
        XCTAssertEqual(PromptProjects.tags(api.tags, settingProjects: ["lantern-web", " a,b ", "LANTERN-WEB", ""]),
                       ["db", "project:lantern-web", "project:a b"])
        XCTAssertEqual(PromptProjects.tags(api.tags, settingProjects: []), ["db"])
        XCTAssertNil(PromptProjects.tags(["project:x"], settingProjects: []))
        XCTAssertNil(PromptProjects.tags(nil, settingProjects: []))
    }

    func test_aLineBreakInAPastedNameCannotSplitThePromptFile() {
        // The Mac writes every tag on one `tags:` line of the prompt file's meta
        // block, so a line break would end that line and start a new meta key.
        XCTAssertEqual(PromptProjects.cleaned("web\nagent: codex"), "web agent: codex")
        XCTAssertEqual(PromptProjects.cleaned("orchard\u{2028}api\t"), "orchard api")
        XCTAssertNil(PromptProjects.cleaned("\n\r\n"))
        XCTAssertEqual(PromptProjects.tags(nil, settingProjects: ["lantern\nweb"]), ["project:lantern web"])
    }

    func test_hubListsThisProjectAndFoldsOtherProjects() {
        let hub = PromptHub.sections([everywhere, api, web], hiddenJSON: "[]", store: [:],
                                     context: nil, query: "", at: now, projectFilter: .project("orchard-api"))
        XCTAssertEqual(Set(hub.visible.map(\.id)), ["ship", "migrate"])
        XCTAssertEqual(hub.otherProjects.map(\.id), ["storybook"])
    }

    func test_hubWithoutAFilterListsEverything() {
        let hub = PromptHub.sections([everywhere, api, web], hiddenJSON: "[]", store: [:],
                                     context: nil, query: "", at: now)
        XCTAssertEqual(hub.visible.count, 3)
        XCTAssertTrue(hub.otherProjects.isEmpty)
    }

    func test_hiddenStaysHiddenAndSearchSortsHitsIntoTheSameSections() {
        let hub = PromptHub.sections([everywhere, api, web], hiddenJSON: "[\"migrate\"]", store: [:],
                                     context: nil, query: "", at: now, projectFilter: .project(nil))
        XCTAssertEqual(hub.visible.map(\.id), ["ship"])
        XCTAssertEqual(hub.hidden.map(\.id), ["migrate"])
        XCTAssertEqual(hub.otherProjects.map(\.id), ["storybook"])

        let search = PromptHub.sections([everywhere, api, web], hiddenJSON: "[]", store: [:],
                                        context: nil, query: "storybook", at: now, projectFilter: .project("orchard-api"))
        XCTAssertTrue(search.visible.isEmpty)
        XCTAssertEqual(search.otherProjects.map(\.id), ["storybook"])
    }
}
