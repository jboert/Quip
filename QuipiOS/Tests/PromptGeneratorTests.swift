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
}
