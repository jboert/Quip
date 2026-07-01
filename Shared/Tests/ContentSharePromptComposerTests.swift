import XCTest
@testable import Quip

final class ContentSharePromptComposerTests: XCTestCase {

    private func fullDraft() -> ContentShareDraft {
        ContentShareDraft(
            schemaVersion: 1,
            sourceApp: "nugget-expo",
            sourceRecordId: "rec_42",
            title: "Firm X acquires Firm Y",
            summary: "A short summary of the deal.",
            sourceUrl: "https://news.example.com/story",
            sourceLabel: "Example News",
            shareUrl: "https://share.example.com/s/abc",
            publishedAt: "2026-06-30T12:00:00Z",
            entities: ["Firm X", "Firm Y"],
            claims: [
                ContentClaim(text: "Deal valued at $1B",
                             sourceUrl: "https://news.example.com/story",
                             status: "verified",
                             note: "confirmed by press release"),
                ContentClaim(text: "Closes Q3", status: "unverified"),
            ],
            suggestedUses: ["summarize", "augment_for_nugget"],
            createdAt: "2026-07-01T00:00:00Z"
        )
    }

    func testAllSectionHeadersPresent() {
        let out = ContentSharePromptComposer.compose(draft: fullDraft(), mode: .summarize)
        XCTAssertTrue(out.contains("Source:"), out)
        XCTAssertTrue(out.contains("Context:"), out)
        XCTAssertTrue(out.contains("Claims:"), out)
        XCTAssertTrue(out.contains("Suggested uses:"), out)
        XCTAssertTrue(out.contains("Requested action:"), out)
    }

    func testIncludesBothSourceAndShareURL() {
        let out = ContentSharePromptComposer.compose(draft: fullDraft(), mode: .summarize)
        XCTAssertTrue(out.contains("https://news.example.com/story"), out)
        XCTAssertTrue(out.contains("https://share.example.com/s/abc"), out)
    }

    func testSourceAttributionNeverDroppedWithOnlyShareURL() {
        var draft = fullDraft()
        draft.sourceUrl = nil
        let out = ContentSharePromptComposer.compose(draft: draft, mode: .summarize)
        // shareUrl must still carry attribution when sourceUrl is absent
        XCTAssertTrue(out.contains("Share URL: https://share.example.com/s/abc"), out)
    }

    func testThreeModesProduceDistinctActions() {
        let draft = fullDraft()
        let s = ContentSharePromptComposer.compose(draft: draft, mode: .summarize)
        let a = ContentSharePromptComposer.compose(draft: draft, mode: .augment_for_nugget)
        let d = ContentSharePromptComposer.compose(draft: draft, mode: .draft_followup)
        XCTAssertNotEqual(s, a)
        XCTAssertNotEqual(a, d)
        XCTAssertNotEqual(s, d)
        XCTAssertEqual(ContentSharePromptMode.allCases.count, 3)
    }

    func testAugmentForNuggetAsksForFourAxes() {
        let out = ContentSharePromptComposer.compose(draft: fullDraft(), mode: .augment_for_nugget)
        XCTAssertTrue(out.contains("Buyer angle"), out)
        XCTAssertTrue(out.contains("Reusable claims"), out)
        XCTAssertTrue(out.contains("Asset gaps"), out)
        XCTAssertTrue(out.contains("Next best action"), out)
    }

    func testDeterministicForSameInput() {
        let draft = fullDraft()
        let a = ContentSharePromptComposer.compose(draft: draft, mode: .augment_for_nugget)
        let b = ContentSharePromptComposer.compose(draft: draft, mode: .augment_for_nugget)
        XCTAssertEqual(a, b)
    }

    func testMinimalDraftOmitsEmptySectionsButKeepsSourceAndAction() {
        let draft = ContentShareDraft(title: "Just a headline",
                                      sourceUrl: "https://news.example.com/x")
        let out = ContentSharePromptComposer.compose(draft: draft, mode: .summarize)
        XCTAssertTrue(out.contains("Source:"), out)
        XCTAssertTrue(out.contains("Title: Just a headline"), out)
        XCTAssertTrue(out.contains("Source URL: https://news.example.com/x"), out)
        XCTAssertTrue(out.contains("Requested action:"), out)
        // no summary / entities / claims / suggested uses → those sections omitted
        XCTAssertFalse(out.contains("Context:"), out)
        XCTAssertFalse(out.contains("Claims:"), out)
        XCTAssertFalse(out.contains("Suggested uses:"), out)
    }

    func testClaimRendersStatusSourceAndNote() {
        let out = ContentSharePromptComposer.compose(draft: fullDraft(), mode: .summarize)
        XCTAssertTrue(out.contains("- Deal valued at $1B [verified]"), out)
        XCTAssertTrue(out.contains("confirmed by press release"), out)
        XCTAssertTrue(out.contains("- Closes Q3 [unverified]"), out)
    }

    func testSourceLabelFallsBackToSourceApp() {
        var draft = fullDraft()
        draft.sourceLabel = nil
        let out = ContentSharePromptComposer.compose(draft: draft, mode: .summarize)
        XCTAssertTrue(out.contains("(nugget-expo)"), out)
    }
}
