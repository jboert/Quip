import XCTest
@testable import Quip

/// PRD broadcast-and-search US-114: `quip://broadcast` links open the
/// Broadcast sheet filled in, and every other link is left alone.
final class BroadcastLinkTests: XCTestCase {
    private typealias Request = BroadcastLink.Request

    private func parse(_ link: String, file: StaticString = #filePath, line: UInt = #line) throws -> Request? {
        BroadcastLink.parse(try XCTUnwrap(URL(string: link), "not a URL: \(link)", file: file, line: line))
    }

    func test_textFillsTheDraft() throws {
        XCTAssertEqual(try parse("quip://broadcast?text=hello"), Request(text: "hello", promptID: nil))
    }

    func test_aPromptIdPreloadsThatPrompt() throws {
        XCTAssertEqual(try parse("quip://broadcast?prompt=ship-it"), Request(text: nil, promptID: "ship-it"))
    }

    func test_aPromptWinsOverText() throws {
        XCTAssertEqual(try parse("quip://broadcast?text=hello&prompt=ship-it"), Request(text: nil, promptID: "ship-it"))
        XCTAssertEqual(try parse("quip://broadcast?prompt=ship-it&text=hello"), Request(text: nil, promptID: "ship-it"))
    }

    func test_aLinkWithNeitherOpensAnEmptySheet() throws {
        let links = ["quip://broadcast", "quip://broadcast/", "quip://broadcast?",
                     "quip://broadcast?text=%20%0A&prompt=", "quip://broadcast?title=hello"]
        for link in links {
            XCTAssertEqual(try parse(link), Request(text: nil, promptID: nil), link)
        }
    }

    func test_aBlankPromptLeavesTheText() throws {
        XCTAssertEqual(try parse("quip://broadcast?prompt=%20&text=hello"), Request(text: "hello", promptID: nil))
    }

    func test_theFirstNonBlankValueOfEachNameIsUsed() throws {
        XCTAssertEqual(try parse("quip://broadcast?text=one&text=two")?.text, "one")
        XCTAssertEqual(try parse("quip://broadcast?text=&text=two")?.text, "two")
    }

    func test_textIsPercentDecodedAndOtherwiseKeptAsSent() throws {
        XCTAssertEqual(try parse("quip://broadcast?text=line%20one%0Aline%20two%20%26%20%F0%9F%9A%80")?.text,
                       "line one\nline two & 🚀")
        // Round trip with every character but ASCII letters and digits encoded,
        // surrounding whitespace included.
        let text = "  Fix it & ship = done?\n50% #1 🚀  "
        let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let encoded = try XCTUnwrap(text.addingPercentEncoding(withAllowedCharacters: ascii))
        XCTAssertEqual(try parse("quip://broadcast?text=\(encoded)")?.text, text)
    }

    func test_schemeAndHostIgnoreCase() throws {
        XCTAssertEqual(try parse("QUIP://Broadcast?text=hi"), Request(text: "hi", promptID: nil))
    }

    func test_otherLinksAreNotBroadcasts() throws {
        let links = ["https://broadcast?text=a", "quip://share?title=a&url=https://example.com",
                     "quip://window/1", "quip://pair?pin=1", "quip://broadcast/x?text=a",
                     "quip:broadcast?text=a", "quip:///broadcast?text=a"]
        for link in links {
            XCTAssertNil(try parse(link), link)
        }
    }
}
