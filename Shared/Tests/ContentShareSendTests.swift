import XCTest
@testable import Quip

final class ContentShareSendTests: XCTestCase {

    private func makeDraft(
        title: String = "Fed cuts rates",
        summary: String? = "The Fed cut rates 25bps.",
        sourceUrl: String? = "https://example.com/article"
    ) -> ContentShareDraft {
        ContentShareDraft(title: title, summary: summary, sourceUrl: sourceUrl)
    }

    // MARK: - Message construction (existing SendTextMessage path)

    func testMessageUsesSendTextPathWithSelectedWindow() {
        let msg = ContentShareSend.message(for: makeDraft(), mode: .summarize, windowId: "w42")
        XCTAssertEqual(msg.type, "send_text")
        XCTAssertEqual(msg.windowId, "w42")
        XCTAssertTrue(msg.pressReturn)
    }

    func testMessageCarriesGeneratedMessageId() {
        let msg = ContentShareSend.message(for: makeDraft(), mode: .summarize, windowId: "w1")
        XCTAssertNotNil(msg.messageId)
    }

    func testMessageIdsAreUniquePerSend() {
        let draft = makeDraft()
        let a = ContentShareSend.message(for: draft, mode: .summarize, windowId: "w1")
        let b = ContentShareSend.message(for: draft, mode: .summarize, windowId: "w1")
        XCTAssertNotEqual(a.messageId, b.messageId)
    }

    func testMessageTextIsExactlyComposerOutputForEveryMode() {
        let draft = makeDraft()
        for mode in ContentSharePromptMode.allCases {
            let msg = ContentShareSend.message(for: draft, mode: mode, windowId: "w1")
            XCTAssertEqual(msg.text, ContentSharePromptComposer.compose(draft: draft, mode: mode))
        }
    }

    // MARK: - Recent-shares MRU (pure)

    func testRecordingInsertsNewestFirst() {
        let older = makeDraft(title: "Older")
        let newer = makeDraft(title: "Newer")
        let recents = ContentShareSend.recording(newer, into: [older])
        XCTAssertEqual(recents, [newer, older])
    }

    func testRecordingDeduplicatesEqualDraftToFront() {
        let a = makeDraft(title: "A")
        let b = makeDraft(title: "B")
        let c = makeDraft(title: "C")
        let recents = ContentShareSend.recording(c, into: [a, b, c])
        XCTAssertEqual(recents, [c, a, b])
    }

    func testRecordingCapsAtTwentyDroppingOldest() {
        var recents: [ContentShareDraft] = []
        for i in 0..<25 {
            recents = ContentShareSend.recording(makeDraft(title: "Item \(i)"), into: recents)
        }
        XCTAssertEqual(recents.count, ContentShareSend.recentSharesCap)
        XCTAssertEqual(recents.first?.title, "Item 24")
        // Items 0-4 fell off the end; item 5 is the oldest survivor.
        XCTAssertEqual(recents.last?.title, "Item 5")
    }

    // MARK: - Persistence round-trip

    func testRecordRecentPersistsAndLoadsRoundTrip() throws {
        let suiteName = "ContentShareSendTests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertEqual(ContentShareSend.loadRecents(from: defaults), [])
        let first = makeDraft(title: "First")
        let second = makeDraft(title: "Second")
        ContentShareSend.recordRecent(first, in: defaults)
        ContentShareSend.recordRecent(second, in: defaults)
        XCTAssertEqual(ContentShareSend.loadRecents(from: defaults), [second, first])
    }

    func testLoadRecentsToleratesUndecodableData() throws {
        let suiteName = "ContentShareSendTests.\(name).garbage"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not json".utf8), forKey: ContentShareSend.recentSharesDefaultsKey)
        XCTAssertEqual(ContentShareSend.loadRecents(from: defaults), [])
    }
}
