import XCTest
@testable import Quip

/// `injection.log` line format.
///
/// The injector's only record of a failure used to be `print`, which reaches
/// neither `~/Library/Logs/Quip/` nor the unified log — a Quip launched from
/// Finder dropped every "iTerm2 session not yet mapped" and every TCC denial on
/// the floor, so "did the keystrokes land?" could only be answered by looking at
/// the user's screen (2026-09-11). These tests pin the format that replaced it.
///
/// The builder is pure and static precisely so this can assert on the text
/// without writing a file.
final class InjectionLogTests: XCTestCase {

    func testLineCarriesOpWindowAppAndKind() {
        let line = KeystrokeInjector.injectionLogLine(
            op: "sendText",
            windowId: "com.googlecode.iterm2.808",
            terminalApp: .iterm2,
            kind: .sessionNotFound,
            message: "iTerm2 session not yet mapped for window com.googlecode.iterm2.808")

        XCTAssertEqual(line,
            #"DROPPED op=sendText window=com.googlecode.iterm2.808 app=iTerm2 "#
            + #"kind=sessionNotFound msg="iTerm2 session not yet mapped for window com.googlecode.iterm2.808""#)
    }

    /// A TCC denial must be distinguishable from a stale session id at a glance:
    /// one self-heals on the next fetch, the other needs a human to re-grant.
    func testTccDenialIsLabelledDistinctly() {
        let line = KeystrokeInjector.injectionLogLine(
            op: "sendKeystroke escape to com.googlecode.iterm2.808 [iTerm2]",
            windowId: "-",
            terminalApp: nil,
            kind: .tccDenied,
            message: "Not authorized to send Apple events to iTerm2.")

        XCTAssertTrue(line.contains("kind=tccDenied"), line)
        XCTAssertTrue(line.contains("app=-"), "A context-only line has no terminal app field")
    }

    /// `unknown` carries its message in the payload, so the kind field stays a
    /// small closed vocabulary a reader can grep for.
    func testUnknownKindDoesNotLeakItsPayloadIntoTheKindField() {
        let line = KeystrokeInjector.injectionLogLine(
            op: "pasteText", windowId: "w1", terminalApp: .terminal,
            kind: .unknown("AppleEvent timed out."),
            message: "AppleEvent timed out.")

        XCTAssertTrue(line.contains("kind=unknown "), line)
        XCTAssertFalse(line.contains("kind=unknown(") , "The associated value belongs in msg, not kind")
    }

    func testMissingClassificationReadsAsUnclassified() {
        let line = KeystrokeInjector.injectionLogLine(
            op: "spawnWindow", windowId: "-", terminalApp: nil,
            kind: nil, message: "boom")

        XCTAssertTrue(line.contains("kind=unclassified"), line)
    }

    /// An AppleScript error is attacker-adjacent text: it can contain whatever
    /// the terminal echoed. A raw newline in it would forge a second log line
    /// and a raw quote would truncate the `msg` field.
    func testQuotesAndNewlinesCannotForgeASecondLine() {
        let line = KeystrokeInjector.injectionLogLine(
            op: "sendText", windowId: "w1", terminalApp: .iterm2,
            kind: .unknown("x"),
            message: "said \"hi\"\nDROPPED op=forged window=evil")

        XCTAssertFalse(line.contains("\n"), "A newline must be escaped, not emitted")
        XCTAssertTrue(line.contains(#"said \"hi\""#), line)
        XCTAssertTrue(line.hasSuffix("\""), "The msg field must still close")
    }

    /// The field grammar is space separated, so an `op` carrying spaces breaks
    /// every reader that splits on whitespace. This used to be the NORMAL case:
    /// `executeAppleScript` passed its whole prose context down as the op, and
    /// that is the path every classified failure takes, TCC denials included.
    func testOpWithSpacesCannotBreakTheFieldGrammar() {
        let line = KeystrokeInjector.injectionLogLine(
            op: "sendText to com.googlecode.iterm2.808 [iTerm2]",
            windowId: "com.googlecode.iterm2.808",
            terminalApp: .iterm2, kind: .tccDenied, message: "denied")

        let fields = line.components(separatedBy: " ")
        XCTAssertEqual(fields[0], "DROPPED")
        XCTAssertEqual(fields[2], "window=com.googlecode.iterm2.808",
                       "The window field must stay in its position: \(line)")
        XCTAssertEqual(fields[3], "app=iTerm2")
    }

    func testEmptyTokenReadsAsADashRatherThanCollapsingTheField() {
        let line = KeystrokeInjector.injectionLogLine(
            op: "spawnWindow", windowId: "", terminalApp: nil,
            kind: nil, message: "boom")

        XCTAssertTrue(line.contains("window=- "), line)
    }

    /// Everything that does not fit a bare token goes in `detail`, quoted and
    /// escaped exactly like `msg` — so the spawn/scroll/keystroke context that
    /// used to live in the op is still recorded, just parseably.
    func testDetailIsQuotedAndOnlyPresentWhenGiven() {
        let withDetail = KeystrokeInjector.injectionLogLine(
            op: "sendKeystroke", windowId: "w1", terminalApp: .iterm2,
            kind: .unknown("x"), message: "boom",
            detail: "key=shift+tab cgWin=808")
        XCTAssertTrue(withDetail.hasSuffix(#"detail="key=shift+tab cgWin=808""#), withDetail)

        let without = KeystrokeInjector.injectionLogLine(
            op: "sendKeystroke", windowId: "w1", terminalApp: .iterm2,
            kind: .unknown("x"), message: "boom")
        XCTAssertFalse(without.contains("detail="), without)
    }

    func testDetailCannotForgeASecondLineEither() {
        let line = KeystrokeInjector.injectionLogLine(
            op: "spawnWindow", windowId: "-", terminalApp: nil,
            kind: nil, message: "boom",
            detail: "cmd=echo \"hi\"\nDROPPED op=forged")

        XCTAssertFalse(line.contains("\n"), "A newline must be escaped, not emitted")
        XCTAssertTrue(line.hasSuffix("\""), "The detail field must still close")
    }

    func testBackslashIsEscapedBeforeQuotes() {
        // Escaping quotes first would leave `\"` ambiguous with an escaped
        // backslash followed by a quote.
        XCTAssertEqual(KeystrokeInjector.injectionLogValue(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(KeystrokeInjector.injectionLogValue("a\rb"), #"a\rb"#)
    }
}
