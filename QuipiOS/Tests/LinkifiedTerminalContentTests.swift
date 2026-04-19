import XCTest
import SwiftUI
@testable import Quip

final class LinkifiedTerminalContentTests: XCTestCase {

    func test_httpsURL_getsLinkAttribute() {
        let raw = "see https://github.com/anthropic for context"
        let attr = linkifiedTerminalContent(raw)

        let urlRanges = attr.runs.filter { $0.link != nil }.map { $0.range }
        XCTAssertEqual(urlRanges.count, 1, "exactly one URL run expected")

        let runRange = try! XCTUnwrap(urlRanges.first)
        XCTAssertEqual(String(attr[runRange].characters), "https://github.com/anthropic")

        let link = attr[runRange].link
        XCTAssertEqual(link?.absoluteString, "https://github.com/anthropic")
    }

    func test_httpURL_getsLinkAttribute() {
        let raw = "fallback http://example.com here"
        let attr = linkifiedTerminalContent(raw)

        let runs = attr.runs.filter { $0.link != nil }
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.link?.absoluteString, "http://example.com")
    }

    func test_filePath_isNotLinked() {
        // The whole reason bare-domain matching is disabled — file paths must not turn into links.
        let raw = "edit Sources/Foo.swift line 42"
        let attr = linkifiedTerminalContent(raw)

        let linkRuns = attr.runs.filter { $0.link != nil }
        XCTAssertTrue(linkRuns.isEmpty, "file paths should not be linkified")
    }

    func test_bareDomain_isNotLinked() {
        let raw = "go to github.com to clone"
        let attr = linkifiedTerminalContent(raw)

        let linkRuns = attr.runs.filter { $0.link != nil }
        XCTAssertTrue(linkRuns.isEmpty, "bare domains without scheme should not be linkified")
    }

    /// `.md` is Moldova's TLD, so NSDataDetector happily matches `README.md`
    /// without the scheme filter — exactly the false positive Claude Code output
    /// would expose constantly.
    func test_markdownFile_isNotLinked() {
        let raw = "see README.md for setup"
        let attr = linkifiedTerminalContent(raw)

        let linkRuns = attr.runs.filter { $0.link != nil }
        XCTAssertTrue(linkRuns.isEmpty, "README.md must not be linkified")
    }

    /// `.app` is a real TLD (Google), so `Quip.app` would otherwise become a link.
    func test_appBundle_isNotLinked() {
        let raw = "rebuild Quip.app and reinstall"
        let attr = linkifiedTerminalContent(raw)

        let linkRuns = attr.runs.filter { $0.link != nil }
        XCTAssertTrue(linkRuns.isEmpty, "Quip.app must not be linkified")
    }

    func test_multipleURLs_allTagged() {
        let raw = "https://a.com and https://b.com/path?q=1"
        let attr = linkifiedTerminalContent(raw)

        let links = attr.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(Set(links), ["https://a.com", "https://b.com/path?q=1"])
    }

    func test_emptyString_returnsEmptyAttributedString() {
        let attr = linkifiedTerminalContent("")
        XCTAssertEqual(String(attr.characters), "")
    }

    func test_noURL_returnsPlainAttributedString() {
        let raw = "just some terminal output, no links"
        let attr = linkifiedTerminalContent(raw)
        XCTAssertEqual(String(attr.characters), raw)
        XCTAssertTrue(attr.runs.allSatisfy { $0.link == nil })
    }
}
