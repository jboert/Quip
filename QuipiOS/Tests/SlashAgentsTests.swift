import XCTest
@testable import Quip

/// Q-72: the slash palette, its search and the prompts hub list what works in
/// the selected window's agent. Commands for every agent always stay; a plain
/// shell lists everything.
final class SlashAgentsTests: XCTestCase {
    typealias Member = MainiOSView.SlashGroupMember

    // MARK: The rule

    func test_universalShowsEverywhere() {
        for window in [CLIKind.claude, .codex, .grok, .cursor, .shell] {
            XCTAssertTrue(SlashAgents.shows([], in: window), window.rawValue)
        }
        XCTAssertTrue(SlashAgents.shows([], in: nil))
    }

    func test_taggedShowsOnlyInItsAgents() {
        XCTAssertTrue(SlashAgents.shows([.claude], in: .claude))
        XCTAssertFalse(SlashAgents.shows([.claude], in: .codex))
        XCTAssertTrue(SlashAgents.shows([.claude, .codex], in: .codex))
        XCTAssertFalse(SlashAgents.shows([.codex], in: .cursor))
    }

    func test_shellAndUnknownWindowsShowEverything() {
        XCTAssertTrue(SlashAgents.shows([.claude], in: .shell))
        XCTAssertTrue(SlashAgents.shows([.codex], in: nil))
    }

    // MARK: Built-ins

    func test_claudePluginCommandsAreClaudeOnly() {
        for b in [QuickButton.btw, .prd, .commitPushPr, .caveman, .ultraReview,
                  .brainstorm, .writePlan, .executePlan, .context] {
            XCTAssertEqual(b.agents, [.claude], b.rawValue)
        }
    }

    func test_codexOnlyCommands() {
        for b in [QuickButton.newChat, .diff, .review, .side] {
            XCTAssertEqual(b.agents, [.codex], b.rawValue)
            XCTAssertTrue(b.isSlashCommand, b.rawValue)
        }
    }

    func test_commandsBothAgentsHave() {
        for b in [QuickButton.compact, .clearContext, .resume, .model, .initProject, .status, .permissions, .mcp] {
            XCTAssertEqual(b.agents, [.claude, .codex], b.rawValue)
        }
    }

    func test_bareSlashAndNonSlashButtonsAreUniversal() {
        XCTAssertEqual(QuickButton.slash.agents, [])
        for b in QuickButton.allCases where !b.isSlashCommand {
            XCTAssertEqual(b.agents, [], b.rawValue)
        }
    }

    func test_codexCommandsSendTheirText() {
        XCTAssertEqual(text(.newChat), "/new")
        XCTAssertEqual(text(.diff), "/diff")
        XCTAssertEqual(text(.review), "/review")
        XCTAssertEqual(text(.side), "/side ")
        XCTAssertEqual(text(.initProject), "/init")
        XCTAssertEqual(text(.status), "/status")
        XCTAssertEqual(text(.permissions), "/permissions")
        XCTAssertEqual(text(.mcp), "/mcp")
    }

    // MARK: The palette list

    func test_codexWindowHidesClaudeCommands() {
        let shown = SlashAgents.filter(allBuiltins(), window: .codex).map(\.displayName)
        XCTAssertTrue(shown.contains("/"))
        XCTAssertTrue(shown.contains("/model"))
        XCTAssertTrue(shown.contains("/diff"))
        XCTAssertFalse(shown.contains("/btw"))
        XCTAssertFalse(shown.contains("/superpowers:brainstorming"))
    }

    func test_claudeWindowHidesCodexCommands() {
        let shown = SlashAgents.filter(allBuiltins(), window: .claude).map(\.displayName)
        XCTAssertTrue(shown.contains("/btw"))
        XCTAssertTrue(shown.contains("/compact"))
        XCTAssertFalse(shown.contains("/diff"))
        XCTAssertFalse(shown.contains("/side"))
    }

    func test_shellWindowListsEveryCommand() {
        XCTAssertEqual(SlashAgents.filter(allBuiltins(), window: .shell).count, allBuiltins().count)
        XCTAssertEqual(SlashAgents.filter(allBuiltins(), window: nil).count, allBuiltins().count)
    }

    func test_filterKeepsOrder() {
        let members = allBuiltins()
        let shown = SlashAgents.filter(members, window: .claude).map(\.id)
        XCTAssertEqual(shown, members.map(\.id).filter(shown.contains))
    }

    // MARK: Custom buttons

    func test_customButtonFollowsItsAgents() {
        let codex = custom(agents: ["codex"])
        XCTAssertEqual(SlashAgents.filter([.custom(codex)], window: .claude).count, 0)
        XCTAssertEqual(SlashAgents.filter([.custom(codex)], window: .codex).count, 1)
        XCTAssertEqual(SlashAgents.filter([.custom(custom(agents: nil))], window: .codex).count, 1)
    }

    func test_customButtonSavedBeforeAgentsDecodesAsUniversal() throws {
        let id = UUID()
        let json = #"[{"id":"\#(id.uuidString)","label":"/help","payload":{"kind":"slash","text":"/help","autoSubmit":true}}]"#
        let decoded = CustomButtonStore.decode(json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded.first?.agentIDs)
        XCTAssertEqual(decoded.first?.agents, [])
    }

    func test_customButtonAgentsRoundTrip() throws {
        let button = custom(agents: ["claude", "codex"])
        let data = try JSONEncoder().encode([button])
        let decoded = try JSONDecoder().decode([CustomButton].self, from: data)
        XCTAssertEqual(decoded.first?.agents, [.claude, .codex])
    }

    func test_unknownAgentFromNewerBuildDoesNotHideTheButton() {
        let button = custom(agents: ["someFutureAgent"])
        XCTAssertEqual(button.agents, [])
        XCTAssertEqual(SlashAgents.filter([.custom(button)], window: .codex).count, 1)
    }

    // MARK: Prompts hub

    func test_promptForAnotherAgentFoldsAway() {
        let library = [prompt("a", agent: nil), prompt("b", agent: "any"),
                       prompt("c", agent: "claude"), prompt("d", agent: "codex")]
        let hub = PromptHub.sections(library, hiddenJSON: "[]", store: [:], context: "claude",
                                     query: "", at: Date(), projectFilter: .project(nil))
        XCTAssertEqual(Set(hub.visible.map(\.id)), ["a", "b", "c"])
        XCTAssertEqual(hub.otherAgents.map(\.id), ["d"])
    }

    func test_promptAgentMatchIgnoresCase() {
        let hub = PromptHub.sections([prompt("a", agent: "Codex")], hiddenJSON: "[]", store: [:],
                                     context: "codex", query: "", at: Date(), projectFilter: .project(nil))
        XCTAssertEqual(hub.visible.map(\.id), ["a"])
    }

    func test_shellWindowShowsEveryPrompt() {
        let library = [prompt("c", agent: "claude"), prompt("d", agent: "codex")]
        for context in ["shell", nil] as [String?] {
            let hub = PromptHub.sections(library, hiddenJSON: "[]", store: [:], context: context,
                                         query: "", at: Date(), projectFilter: .project(nil))
            XCTAssertEqual(hub.visible.count, 2)
            XCTAssertTrue(hub.otherAgents.isEmpty)
        }
    }

    func test_searchStillFindsOtherAgentPrompts() {
        let library = [prompt("deploy", agent: "codex")]
        let hub = PromptHub.sections(library, hiddenJSON: "[]", store: [:], context: "claude",
                                     query: "deploy", at: Date(), projectFilter: .project(nil))
        XCTAssertTrue(hub.visible.isEmpty)
        XCTAssertEqual(hub.otherAgents.map(\.id), ["deploy"])
    }

    func test_managementListKeepsEveryPromptVisible() {
        let hub = PromptHub.sections([prompt("d", agent: "codex")], hiddenJSON: "[]", store: [:],
                                     context: "claude", query: "", at: Date())
        XCTAssertEqual(hub.visible.map(\.id), ["d"])
    }

    // MARK: Helpers

    private func allBuiltins() -> [Member] {
        QuickButton.allCases.filter(\.isSlashCommand).map { .builtin($0) }
    }

    private func text(_ b: QuickButton) -> String? {
        if case .sendText(let t, _) = b.action { return t }
        return nil
    }

    private func custom(agents: [String]?) -> CustomButton {
        CustomButton(id: UUID(), label: "/x", systemImage: nil,
                     payload: .slash(text: "/x", autoSubmit: true), agentIDs: agents)
    }

    private func prompt(_ id: String, agent: String?) -> PromptEntry {
        PromptEntry(id: id, label: id, body: "body of \(id)", targetAgent: agent)
    }
}
