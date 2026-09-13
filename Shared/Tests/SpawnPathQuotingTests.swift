#if os(macOS)
import XCTest
@testable import Quip

/// Spawn paths compose two escapes: shell first (the string ends up inside
/// `cd "…"` in a shell), then AppleScript (the whole command is a string
/// literal in a `do script` / `write text` call). Getting the order or the
/// character set wrong turns a directory name into a command.
final class SpawnPathQuotingTests: XCTestCase {

    func testShellEscapeNeutralizesExpansionCharacters() {
        let escaped = KeystrokeInjector.escapeForShellStatic("/Users/me/$HOME/`whoami`")
        XCTAssertEqual(escaped, #"/Users/me/\$HOME/\`whoami\`"#)
        XCTAssertTrue(everyOccurrenceIsEscaped(of: "$", in: escaped),
                      "A bare $ expands inside double quotes")
        XCTAssertTrue(everyOccurrenceIsEscaped(of: "`", in: escaped),
                      "A bare backtick command-substitutes inside double quotes")
    }

    /// True when every `needle` in `text` is immediately preceded by a
    /// backslash — i.e. nothing was left live for the shell to interpret.
    private func everyOccurrenceIsEscaped(of needle: Character, in text: String) -> Bool {
        var previous: Character?
        for ch in text {
            if ch == needle, previous != "\\" { return false }
            previous = ch
        }
        return true
    }

    func testShellEscapeQuotesEmbeddedDoubleQuote() {
        XCTAssertEqual(KeystrokeInjector.escapeForShellStatic(#"/tmp/a"b"#), #"/tmp/a\"b"#)
    }

    func testShellEscapeDoublesBackslashesFirst() {
        // A path ending in a backslash must not swallow the closing quote.
        XCTAssertEqual(KeystrokeInjector.escapeForShellStatic(#"/tmp/back\"#), #"/tmp/back\\"#)
    }

    func testPathsWithSpacesSurviveBothLayers() {
        let composed = KeystrokeInjector.escapeForAppleScriptStatic(
            KeystrokeInjector.escapeForShellStatic("/Users/me/My Projects/quip")
        )
        XCTAssertTrue(composed.contains("My Projects"),
                      "Spaces need no escaping — the surrounding quotes handle them")
    }

    /// The composition order is load-bearing: AppleScript escaping must run
    /// last, otherwise the backslashes the shell escape introduced are
    /// themselves left unescaped in the AppleScript literal.
    func testAppleScriptEscapeRunsLastAndEscapesShellBackslashes() {
        let shellOnly = KeystrokeInjector.escapeForShellStatic("/tmp/$X")
        XCTAssertEqual(shellOnly, #"/tmp/\$X"#)
        XCTAssertEqual(KeystrokeInjector.escapeForAppleScriptStatic(shellOnly), #"/tmp/\\$X"#)
    }

    func testEmptyPathStaysEmpty() {
        XCTAssertEqual(KeystrokeInjector.escapeForShellStatic(""), "")
    }
}
#endif
