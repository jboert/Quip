import XCTest
@testable import Quip

final class ContentShareDraftTests: XCTestCase {

    private func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]  // deterministic field order for external consumers
        return enc
    }

    // MARK: - Full round-trip

    func testFullRoundTrip() throws {
        let original = ContentShareDraft(
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

        let data = try makeEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentShareDraft.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - Minimal decode

    func testMinimalDecodeDefaultsArraysAndNils() throws {
        let json = #"{"title":"Just a headline","sourceUrl":"https://news.example.com/x"}"#
        let draft = try JSONDecoder().decode(ContentShareDraft.self, from: Data(json.utf8))

        XCTAssertEqual(draft.title, "Just a headline")
        XCTAssertEqual(draft.sourceUrl, "https://news.example.com/x")
        // schemaVersion defaults when absent
        XCTAssertEqual(draft.schemaVersion, ContentShareDraft.currentSchemaVersion)
        // optional arrays default to empty
        XCTAssertEqual(draft.entities, [])
        XCTAssertEqual(draft.claims, [])
        XCTAssertEqual(draft.suggestedUses, [])
        // optional strings default to nil
        XCTAssertNil(draft.sourceApp)
        XCTAssertNil(draft.sourceRecordId)
        XCTAssertNil(draft.summary)
        XCTAssertNil(draft.sourceLabel)
        XCTAssertNil(draft.shareUrl)
        XCTAssertNil(draft.publishedAt)
        XCTAssertNil(draft.createdAt)
    }

    // MARK: - Unknown extra field tolerance

    func testUnknownExtraFieldsAreIgnored() throws {
        let json = """
        {
          "title": "Headline",
          "sourceUrl": "https://news.example.com/x",
          "futureField": "some value the current app does not know about",
          "nestedUnknown": {"a": 1, "b": [true, false]},
          "entities": ["A"]
        }
        """
        let draft = try JSONDecoder().decode(ContentShareDraft.self, from: Data(json.utf8))

        XCTAssertEqual(draft.title, "Headline")
        XCTAssertEqual(draft.sourceUrl, "https://news.example.com/x")
        XCTAssertEqual(draft.entities, ["A"])
        XCTAssertEqual(draft.claims, [])
    }

    // MARK: - Claim decode tolerance

    func testClaimMinimalDecode() throws {
        let json = #"{"title":"H","claims":[{"text":"bare claim"}]}"#
        let draft = try JSONDecoder().decode(ContentShareDraft.self, from: Data(json.utf8))

        XCTAssertEqual(draft.claims.count, 1)
        XCTAssertEqual(draft.claims.first?.text, "bare claim")
        XCTAssertNil(draft.claims.first?.sourceUrl)
        XCTAssertNil(draft.claims.first?.status)
        XCTAssertNil(draft.claims.first?.note)
    }

    // MARK: - Deterministic field names

    func testEncodesExpectedFieldNames() throws {
        let draft = ContentShareDraft(title: "H", sourceUrl: "https://x")
        let data = try makeEncoder().encode(draft)
        let string = String(decoding: data, as: UTF8.self)

        // Non-Swift consumers rely on these exact camelCase keys.
        XCTAssertTrue(string.contains("\"schemaVersion\":1"), string)
        XCTAssertTrue(string.contains("\"title\":\"H\""), string)
        XCTAssertTrue(string.contains("\"sourceUrl\":\"https:\\/\\/x\""), string)
        XCTAssertTrue(string.contains("\"entities\":[]"), string)
        XCTAssertTrue(string.contains("\"claims\":[]"), string)
        XCTAssertTrue(string.contains("\"suggestedUses\":[]"), string)
        // nil optionals are omitted
        XCTAssertFalse(string.contains("\"summary\""), string)
    }
}
