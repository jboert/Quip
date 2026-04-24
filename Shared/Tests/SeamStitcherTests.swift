import XCTest
@testable import Quip

final class SeamStitcherTests: XCTestCase {
    func testExactThreeWordOverlapIsRemoved() {
        let old = "the quick brown fox"
        let new = "brown fox jumps over"
        XCTAssertEqual(SeamStitcher.stitch(old: old, new: new),
                       "the quick brown fox jumps over")
    }

    func testOneWordOverlapIsRemoved() {
        let old = "hello world"
        let new = "world goodbye"
        XCTAssertEqual(SeamStitcher.stitch(old: old, new: new),
                       "hello world goodbye")
    }

    func testNoOverlapFallsBackToConcat() {
        let old = "hello world"
        let new = "goodbye cruel world"
        XCTAssertEqual(SeamStitcher.stitch(old: old, new: new),
                       "hello world goodbye cruel world")
    }

    func testCaseInsensitiveMatch() {
        let old = "hello World"
        let new = "world again"
        XCTAssertEqual(SeamStitcher.stitch(old: old, new: new),
                       "hello World again")
    }

    func testEmptyOldReturnsNew() {
        XCTAssertEqual(SeamStitcher.stitch(old: "", new: "hi there"), "hi there")
    }

    func testEmptyNewReturnsOld() {
        XCTAssertEqual(SeamStitcher.stitch(old: "hi there", new: ""), "hi there")
    }

    func testPrefersLongestOverlap() {
        let old = "x a b c"
        let new = "b c d e"
        XCTAssertEqual(SeamStitcher.stitch(old: old, new: new),
                       "x a b c d e")
    }
}
