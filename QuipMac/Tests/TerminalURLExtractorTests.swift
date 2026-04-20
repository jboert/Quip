import XCTest
@testable import Quip

/// Mirror of LinkifiedTerminalContentTests on the iOS side — the two
/// rulesets must agree, so the same scenarios are pinned here. Adding a
/// test on one side without the other is a smell: the tray would show
/// URLs iOS can't tap, or iOS would tap URLs the Mac filtered out.
final class TerminalURLExtractorTests: XCTestCase {

    func test_https_url_is_extracted() {
        let urls = TerminalURLExtractor.extract(from: "see https://github.com/anthropic for context")
        XCTAssertEqual(urls, ["https://github.com/anthropic"])
    }

    func test_http_url_is_extracted() {
        let urls = TerminalURLExtractor.extract(from: "fallback http://example.com here")
        XCTAssertEqual(urls, ["http://example.com"])
    }

    func test_file_path_is_not_extracted() {
        let urls = TerminalURLExtractor.extract(from: "edit Sources/Foo.swift line 42")
        XCTAssertEqual(urls, [])
    }

    func test_bare_domain_is_not_extracted() {
        let urls = TerminalURLExtractor.extract(from: "go to github.com to clone")
        XCTAssertEqual(urls, [])
    }

    func test_markdown_file_is_not_extracted() {
        let urls = TerminalURLExtractor.extract(from: "see README.md for setup")
        XCTAssertEqual(urls, [])
    }

    func test_app_bundle_is_not_extracted() {
        let urls = TerminalURLExtractor.extract(from: "rebuild Quip.app and reinstall")
        XCTAssertEqual(urls, [])
    }

    func test_bare_email_is_extracted_as_mailto() {
        let urls = TerminalURLExtractor.extract(from: "contact noreply@anthropic.com for support")
        XCTAssertEqual(urls, ["mailto:noreply@anthropic.com"])
    }

    func test_explicit_mailto_is_extracted() {
        let urls = TerminalURLExtractor.extract(from: "or use mailto:hi@example.com directly")
        XCTAssertEqual(urls, ["mailto:hi@example.com"])
    }

    func test_multiple_urls_extracted_in_order() {
        let urls = TerminalURLExtractor.extract(from: "see https://a.com then https://b.com/path?q=1")
        XCTAssertEqual(urls, ["https://a.com", "https://b.com/path?q=1"])
    }

    func test_duplicate_urls_are_deduped() {
        // Terminal scrollback repeats URLs often (tail -f logs, etc.). The
        // tray shouldn't render the same pill twice — wastes screen real estate.
        let urls = TerminalURLExtractor.extract(from: "https://a.com and again https://a.com end")
        XCTAssertEqual(urls, ["https://a.com"])
    }

    func test_empty_string() {
        XCTAssertEqual(TerminalURLExtractor.extract(from: ""), [])
    }

    func test_no_urls() {
        XCTAssertEqual(TerminalURLExtractor.extract(from: "just terminal output, nothing linkable"), [])
    }
}
