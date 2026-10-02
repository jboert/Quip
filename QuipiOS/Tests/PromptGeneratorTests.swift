import XCTest
@testable import Quip

final class PromptGeneratorTests: XCTestCase {

    func test_makeEntry_usesSanitizedUniqueIDAndMetadata() {
        var input = PromptGeneratorInput.empty
        input.title = "Review PR!"
        input.targetAgent = .codex
        input.outputStyle = .codeReview
        input.goal = "Find risky changes"

        let entry = PromptGenerator.makeEntry(from: input, existingIDs: ["review-pr"])

        XCTAssertEqual(entry.id, "review-pr-2")
        XCTAssertEqual(entry.label, "Review PR!")
        XCTAssertEqual(entry.tags, ["generated", "codeReview"])
        XCTAssertEqual(entry.targetAgent, "codex")
        XCTAssertEqual(entry.description, "Find risky changes")
    }

    func test_makeBody_includesSelectedBehaviorAndBoundaries() {
        var input = PromptGeneratorInput.empty
        input.targetAgent = .claude
        input.outputStyle = .debug
        input.goal = "Fix prompt saves"
        input.context = "iOS talks to Mac over WebSocket."
        input.constraints = "Keep the existing ack flow."
        input.successCriteria = "A failed save stays open."
        input.askClarifyingQuestions = true

        let body = PromptGenerator.makeBody(from: input)

        XCTAssertTrue(body.contains("You are Claude working inside Quip."))
        XCTAssertTrue(body.contains("Trace the failure from observed symptom to root cause"))
        XCTAssertTrue(body.contains("Ask concise clarifying questions before acting"))
        XCTAssertTrue(body.contains("Respect these constraints: Keep the existing ack flow."))
        XCTAssertTrue(body.contains("A failed save stays open."))
    }

    func test_sanitizedID_collapsesSeparatorsAndFallsBack() {
        XCTAssertEqual(PromptGenerator.sanitizedID("  Ship it / now  "), "ship-it-now")
        XCTAssertEqual(PromptGenerator.uniqueID(base: "!!!", existingIDs: []), "generated-prompt")
    }

    // MARK: - Q-35: seeded from usage

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func store(_ fires: [(String, String?)]) -> PromptRanker.Store {
        fires.reduce(into: PromptRanker.Store()) { store, fire in
            store = PromptRanker.recording(fire.0, context: fire.1, at: now, in: store)
        }
    }

    func test_topExamples_skipsNeverFiredPromptsAndFollowsContext() {
        let prompts = [
            PromptEntry(id: "a", label: "A", body: "a"),
            PromptEntry(id: "b", label: "B", body: "b"),
            PromptEntry(id: "never", label: "Never", body: "n"),
        ]
        let usage = store([("a", "codex"), ("a", "codex"), ("b", "claude"), ("b", "claude"), ("b", "claude")])

        XCTAssertEqual(PromptGenerator.topExamples(prompts, store: usage, context: "codex", at: now).map(\.id), ["a", "b"])
        XCTAssertEqual(PromptGenerator.topExamples(prompts, store: usage, context: "claude", at: now).map(\.id), ["b", "a"])
        XCTAssertEqual(PromptGenerator.topExamples(prompts, store: usage, context: nil, at: now, limit: 1).map(\.id), ["b"])
        XCTAssertTrue(PromptGenerator.topExamples(prompts, store: [:], context: nil, at: now).isEmpty)
    }

    func test_agentForContext_mapsOnlyPickableAgents() {
        XCTAssertEqual(PromptGenerator.agent(forContext: "claude"), .claude)
        XCTAssertEqual(PromptGenerator.agent(forContext: "codex"), .codex)
        XCTAssertEqual(PromptGenerator.agent(forContext: "grok"), .grok)
        // Cursor is not in the picker, so selecting it would leave the Picker
        // with no matching tag.
        XCTAssertEqual(PromptGenerator.agent(forContext: "cursor"), .any)
        XCTAssertEqual(PromptGenerator.agent(forContext: "shell"), .any)
        XCTAssertEqual(PromptGenerator.agent(forContext: nil), .any)
    }

    func test_initialInput_takesAgentFromWindowAndStyleFromHabits() {
        let examples = [
            PromptEntry(id: "1", label: "1", body: "", tags: ["generated", "debug"]),
            PromptEntry(id: "2", label: "2", body: "", tags: ["generated", "debug"]),
            PromptEntry(id: "3", label: "3", body: "", tags: ["generated", "codeReview"]),
            PromptEntry(id: "4", label: "4", body: "plain prompt, no tags"),
        ]

        let input = PromptGenerator.initialInput(context: "codex", examples: examples)

        XCTAssertEqual(input.targetAgent, .codex)
        XCTAssertEqual(input.outputStyle, .debug)
        XCTAssertEqual(input.goal, "")
    }

    func test_initialInput_withoutHabitsKeepsDefaults() {
        let input = PromptGenerator.initialInput(context: nil, examples: [PromptEntry(id: "x", label: "X", body: "x")])
        XCTAssertEqual(input, .empty)
    }

    func test_initialInput_styleTieGoesToTheHigherRankedPrompt() {
        let examples = [
            PromptEntry(id: "1", label: "1", body: "", tags: ["generated", "planning"]),
            PromptEntry(id: "2", label: "2", body: "", tags: ["generated", "debug"]),
        ]
        XCTAssertEqual(PromptGenerator.initialInput(context: nil, examples: examples).outputStyle, .planning)
    }

    func test_seeded_generatedPromptRestoresGoalStyleAndAgent() {
        let entry = PromptEntry(
            id: "fix", label: "Fix saves", body: "You are Codex working inside Quip.",
            tags: ["generated", "debug"], targetAgent: "codex", description: "Fix prompt saves"
        )
        var base = PromptGeneratorInput.empty
        base.title = "old title"
        base.context = "kept context"

        let input = PromptGenerator.seeded(from: entry, base: base)

        XCTAssertEqual(input.goal, "Fix prompt saves")
        XCTAssertEqual(input.outputStyle, .debug)
        XCTAssertEqual(input.targetAgent, .codex)
        XCTAssertEqual(input.title, "", "a seed is a new prompt, so the old name must not carry over")
        XCTAssertEqual(input.context, "kept context")
    }

    func test_seeded_plainPromptUsesFirstBodyLineAndKeepsBaseAgent() {
        let entry = PromptEntry(id: "p", label: "P", body: "\n\n  Run the tests and fix failures.  \nThen commit.", targetAgent: "any")
        var base = PromptGeneratorInput.empty
        base.targetAgent = .claude
        base.outputStyle = .planning

        let input = PromptGenerator.seeded(from: entry, base: base)

        XCTAssertEqual(input.goal, "Run the tests and fix failures.")
        XCTAssertEqual(input.targetAgent, .claude, "\"any\" on a prompt must not override the window's agent")
        XCTAssertEqual(input.outputStyle, .planning)
    }

    func test_seeded_capsAVeryLongFirstLine() {
        let entry = PromptEntry(id: "p", label: "P", body: String(repeating: "x", count: 500))
        XCTAssertEqual(PromptGenerator.seeded(from: entry, base: .empty).goal.count, PromptGenerator.seedGoalLimit)
    }
}
