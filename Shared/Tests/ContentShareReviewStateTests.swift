import XCTest
@testable import Quip

final class ContentShareReviewStateTests: XCTestCase {

    private func makeDraft(
        title: String = "Fed cuts rates",
        summary: String? = "The Fed cut rates 25bps.",
        sourceUrl: String? = "https://example.com/article",
        sourceLabel: String? = nil,
        sourceApp: String? = nil,
        shareUrl: String? = nil
    ) -> ContentShareDraft {
        ContentShareDraft(
            sourceApp: sourceApp,
            title: title,
            summary: summary,
            sourceUrl: sourceUrl,
            sourceLabel: sourceLabel,
            shareUrl: shareUrl
        )
    }

    // MARK: - Send gate

    func testCannotSendWithoutWindowOrConnection() {
        let state = ContentShareReviewState(draft: makeDraft(), mode: .summarize)
        XCTAssertFalse(state.canSend)
    }

    func testCannotSendWithWindowButDisconnected() {
        let state = ContentShareReviewState(
            draft: makeDraft(), mode: .summarize,
            selectedWindowId: "w1", selectedWindowName: "claude", isConnected: false)
        XCTAssertFalse(state.canSend)
    }

    func testCannotSendConnectedButNoWindow() {
        let state = ContentShareReviewState(
            draft: makeDraft(), mode: .summarize,
            selectedWindowId: nil, isConnected: true)
        XCTAssertFalse(state.canSend)
    }

    func testCanSendWhenWindowSelectedAndConnected() {
        let state = ContentShareReviewState(
            draft: makeDraft(), mode: .summarize,
            selectedWindowId: "w1", selectedWindowName: "claude", isConnected: true)
        XCTAssertTrue(state.canSend)
    }

    // MARK: - Display fields

    func testDisplaysTitleAndSummary() {
        let state = ContentShareReviewState(draft: makeDraft(), mode: .summarize)
        XCTAssertEqual(state.title, "Fed cuts rates")
        XCTAssertEqual(state.summary, "The Fed cut rates 25bps.")
    }

    func testEmptySummaryIsNil() {
        let state = ContentShareReviewState(draft: makeDraft(summary: ""), mode: .summarize)
        XCTAssertNil(state.summary)
    }

    func testFinalSourceURLPrefersSourceUrl() {
        let draft = makeDraft(sourceUrl: "https://a.com/x", shareUrl: "https://share.co/y")
        let state = ContentShareReviewState(draft: draft, mode: .summarize)
        XCTAssertEqual(state.finalSourceURL, "https://a.com/x")
    }

    func testFinalSourceURLFallsBackToShareUrl() {
        let draft = makeDraft(sourceUrl: nil, shareUrl: "https://share.co/y")
        let state = ContentShareReviewState(draft: draft, mode: .summarize)
        XCTAssertEqual(state.finalSourceURL, "https://share.co/y")
    }

    func testFinalSourceURLNilWhenNoURLs() {
        let draft = makeDraft(sourceUrl: nil, shareUrl: nil)
        let state = ContentShareReviewState(draft: draft, mode: .summarize)
        XCTAssertNil(state.finalSourceURL)
    }

    // MARK: - Source label attribution

    func testSourceLabelPrefersExplicitLabel() {
        let draft = makeDraft(sourceLabel: "Reuters", sourceApp: "nugget-expo")
        let state = ContentShareReviewState(draft: draft, mode: .summarize)
        XCTAssertEqual(state.sourceLabel, "Reuters")
    }

    func testSourceLabelFallsBackToSourceApp() {
        let draft = makeDraft(sourceLabel: nil, sourceApp: "nugget-expo")
        let state = ContentShareReviewState(draft: draft, mode: .summarize)
        XCTAssertEqual(state.sourceLabel, "nugget-expo")
    }

    func testSourceLabelFallsBackToHostOfURL() {
        let draft = makeDraft(
            sourceUrl: "https://www.reuters.com/markets/rates",
            sourceLabel: nil, sourceApp: nil)
        let state = ContentShareReviewState(draft: draft, mode: .summarize)
        XCTAssertEqual(state.sourceLabel, "www.reuters.com")
    }

    func testSourceLabelNilWhenNothingAvailable() {
        let draft = makeDraft(sourceUrl: nil, sourceLabel: nil, sourceApp: nil, shareUrl: nil)
        let state = ContentShareReviewState(draft: draft, mode: .summarize)
        XCTAssertNil(state.sourceLabel)
    }

    // MARK: - Modes + composed prompt

    func testOffersAllThreeModes() {
        XCTAssertEqual(
            ContentShareReviewState.availableModes,
            [.summarize, .augment_for_nugget, .draft_followup])
    }

    func testComposedPromptMatchesSharedComposerForSelectedMode() {
        let draft = makeDraft()
        let state = ContentShareReviewState(draft: draft, mode: .augment_for_nugget)
        XCTAssertEqual(
            state.composedPrompt,
            ContentSharePromptComposer.compose(draft: draft, mode: .augment_for_nugget))
    }

    func testComposedPromptChangesWithMode() {
        let draft = makeDraft()
        let summarize = ContentShareReviewState(draft: draft, mode: .summarize).composedPrompt
        let augment = ContentShareReviewState(draft: draft, mode: .augment_for_nugget).composedPrompt
        XCTAssertNotEqual(summarize, augment)
    }
}
