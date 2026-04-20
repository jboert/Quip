import XCTest
@testable import Quip

final class ClaudeModeScannerTests: XCTestCase {

    // Happy paths: indicator strings in the tail → mode detected.

    func test_detect_planModeFromFooter() {
        let buffer = """
        ... lots of prose above ...
        some claude output here
        ⏵⏵ plan mode on  (shift+tab to cycle)
        """
        XCTAssertEqual(ClaudeModeScanner.detect(in: buffer), .plan)
    }

    func test_detect_autoAcceptFromFooter() {
        let buffer = """
        >>> running edits...
        ⏵⏵ auto-accept edits on  (shift+tab to cycle)
        """
        XCTAssertEqual(ClaudeModeScanner.detect(in: buffer), .autoAccept)
    }

    func test_detect_normalMode_returnsNil() {
        // Normal mode shows no indicator — the scanner returns nil and callers
        // decide whether to treat nil as normal or unknown.
        let buffer = """
        $ claude
        Welcome to Claude Code.
        > your prompt here_
        """
        XCTAssertNil(ClaudeModeScanner.detect(in: buffer))
    }

    func test_detect_emptyBuffer_returnsNil() {
        XCTAssertNil(ClaudeModeScanner.detect(in: ""))
    }

    // Edge case: an indicator string appearing only in transcript prose far above
    // the tail window should NOT be caught. This is the whole reason detect()
    // limits its scan to the last N lines.
    func test_detect_mentionInOldProse_ignoredByTailWindow() {
        // The tail window is the last 40 lines by default — pad with filler so
        // the "plan mode on" mention is pushed above the scan region.
        let filler = Array(repeating: "filler line", count: 60).joined(separator: "\n")
        let buffer = """
        I read a paper that said "plan mode on" changes the behavior.
        \(filler)
        $ bare prompt
        """
        XCTAssertNil(ClaudeModeScanner.detect(in: buffer))
    }

    // Guard: both strings present — plan wins, because plan is the more specific
    // state Claude Code cycles to last in the Shift+Tab order.
    func test_detect_bothIndicators_planWins() {
        let buffer = """
        auto-accept edits on
        plan mode on
        """
        XCTAssertEqual(ClaudeModeScanner.detect(in: buffer), .plan)
    }

    // Case-insensitive matching — Claude Code renders with lowercase but future
    // iterations may change capitalization. We lowercase the tail before matching.
    func test_detect_caseInsensitive() {
        let buffer = "Plan Mode ON"
        XCTAssertEqual(ClaudeModeScanner.detect(in: buffer), .plan)
    }
}
