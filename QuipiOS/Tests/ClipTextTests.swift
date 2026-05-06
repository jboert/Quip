import XCTest
@testable import Quip

/// Locks `MainiOSView.clipText(_:maxBytes:)` byte-cap behavior so the
/// 32 KiB clipboard ceiling for §35 cross-app paste doesn't silently
/// regress (e.g. someone replaces the loop with `prefix(maxBytes)` and
/// silently splits multi-byte glyphs into invalid UTF-8).
final class ClipTextTests: XCTestCase {

    func test_shortString_passesThroughVerbatim() {
        XCTAssertEqual(MainiOSView.clipText("hello", maxBytes: 32_768), "hello")
    }

    func test_emptyString_returnsEmpty() {
        XCTAssertEqual(MainiOSView.clipText("", maxBytes: 32_768), "")
    }

    func test_atLimit_passesThroughVerbatim() {
        let s = String(repeating: "a", count: 100)
        XCTAssertEqual(MainiOSView.clipText(s, maxBytes: 100), s)
    }

    func test_overLimit_truncates() {
        let s = String(repeating: "a", count: 200)
        let out = MainiOSView.clipText(s, maxBytes: 100)
        XCTAssertEqual(out.utf8.count, 100)
        XCTAssertEqual(out, String(repeating: "a", count: 100))
    }

    func test_multiByteGlyph_neverSplit() {
        // "🚀" is 4 UTF-8 bytes. With cap=10, three rockets (12 bytes)
        // wouldn't fit → loop must keep two (8 bytes) instead of slicing
        // mid-glyph and returning invalid UTF-8.
        let s = "🚀🚀🚀"
        let out = MainiOSView.clipText(s, maxBytes: 10)
        XCTAssertEqual(out, "🚀🚀")
        XCTAssertEqual(out.utf8.count, 8)
    }

    func test_smallCap_yieldsEmpty_notInvalidUTF8() {
        // Cap smaller than the first glyph means we get an empty string
        // rather than a truncated (invalid-UTF8) substring.
        XCTAssertEqual(MainiOSView.clipText("🚀", maxBytes: 2), "")
    }
}
