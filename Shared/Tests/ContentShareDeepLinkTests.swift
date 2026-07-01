import XCTest
@testable import Quip

final class ContentShareDeepLinkTests: XCTestCase {

    private func url(_ s: String) -> URL {
        guard let u = URL(string: s) else {
            fatalError("bad test URL: \(s)")
        }
        return u
    }

    // MARK: - quip://share parsing

    func testParsesAllShareParameters() {
        let u = url("quip://share?title=Big%20News&url=https://ex.com/a&summary=A%20short%20summary&source=Example&shareUrl=https://ex.com/s&sourceApp=nugget-expo&sourceRecordId=rec_42&mode=augment_for_nugget")
        guard case let .share(draft, mode) = ContentShareDeepLink.route(for: u) else {
            return XCTFail("expected .share route")
        }
        XCTAssertEqual(draft.title, "Big News")
        XCTAssertEqual(draft.sourceUrl, "https://ex.com/a")
        XCTAssertEqual(draft.summary, "A short summary")
        XCTAssertEqual(draft.sourceLabel, "Example")
        XCTAssertEqual(draft.shareUrl, "https://ex.com/s")
        XCTAssertEqual(draft.sourceApp, "nugget-expo")
        XCTAssertEqual(draft.sourceRecordId, "rec_42")
        XCTAssertEqual(mode, .augment_for_nugget)
        XCTAssertEqual(draft.schemaVersion, ContentShareDraft.currentSchemaVersion)
        XCTAssertEqual(draft.entities, [])
        XCTAssertEqual(draft.claims, [])
    }

    func testPercentDecodingSpacesAmpersandsAndUnicode() {
        // %20 space, %26 ampersand, and percent-encoded UTF-8 (é, 日本語).
        let u = url("quip://share?title=Rates%20rise%20%26%20fall%20caf%C3%A9&url=https://ex.com/x&summary=%E6%97%A5%E6%9C%AC%E8%AA%9E%20test%20%26%20more")
        guard case let .share(draft, _) = ContentShareDeepLink.route(for: u) else {
            return XCTFail("expected .share route")
        }
        XCTAssertEqual(draft.title, "Rates rise & fall café")
        XCTAssertEqual(draft.summary, "日本語 test & more")
    }

    func testUrlOnlyFallsBackToTitle() {
        // Minimal payload: only url. Title falls back so attribution survives.
        let u = url("quip://share?url=https://ex.com/only")
        guard case let .share(draft, mode) = ContentShareDeepLink.route(for: u) else {
            return XCTFail("expected .share route")
        }
        XCTAssertEqual(draft.title, "https://ex.com/only")
        XCTAssertEqual(draft.sourceUrl, "https://ex.com/only")
        XCTAssertNil(mode)  // no mode param → nil
    }

    func testTitleOnlyParses() {
        let u = url("quip://share?title=Headline%20only")
        guard case let .share(draft, _) = ContentShareDeepLink.route(for: u) else {
            return XCTFail("expected .share route")
        }
        XCTAssertEqual(draft.title, "Headline only")
        XCTAssertNil(draft.sourceUrl)
    }

    func testEmptyTitleParamFallsThroughToUrl() {
        // ?title= (empty) is treated as absent; url anchors the draft.
        let u = url("quip://share?title=&url=https://ex.com/z")
        guard case let .share(draft, _) = ContentShareDeepLink.route(for: u) else {
            return XCTFail("expected .share route")
        }
        XCTAssertEqual(draft.title, "https://ex.com/z")
    }

    func testUnknownModeIsNil() {
        let u = url("quip://share?title=X&mode=bogus")
        guard case let .share(_, mode) = ContentShareDeepLink.route(for: u) else {
            return XCTFail("expected .share route")
        }
        XCTAssertNil(mode)
    }

    // MARK: - malformed shares are a no-op

    func testMalformedShareWithNoTitleOrUrlIsNone() {
        XCTAssertEqual(ContentShareDeepLink.route(for: url("quip://share")), .none)
        XCTAssertEqual(ContentShareDeepLink.route(for: url("quip://share?summary=orphan")), .none)
        XCTAssertNil(ContentShareDeepLink.parseShare(url("quip://share")))
    }

    // MARK: - existing routes preserved

    func testPairRoutePreserved() {
        XCTAssertEqual(ContentShareDeepLink.route(for: url("quip://pair?url=wss://x&pin=1234")), .pair)
    }

    func testPermsRoutePreserved() {
        XCTAssertEqual(ContentShareDeepLink.route(for: url("quip://perms")), .perms)
    }

    func testWindowRoutePreserved() {
        XCTAssertEqual(ContentShareDeepLink.route(for: url("quip://window/win-7")), .window("win-7"))
    }

    func testLegacyWindowRoutePreserved() {
        // quip://<windowId> with no "window/" prefix.
        XCTAssertEqual(ContentShareDeepLink.route(for: url("quip://abc123")), .window("abc123"))
    }

    func testWindowWithEmptyIdIsNone() {
        XCTAssertEqual(ContentShareDeepLink.route(for: url("quip://window/")), .none)
    }

    func testNonQuipSchemeIsNone() {
        XCTAssertEqual(ContentShareDeepLink.route(for: url("https://share?title=X")), .none)
    }
}
