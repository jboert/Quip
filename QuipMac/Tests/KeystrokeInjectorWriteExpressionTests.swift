import XCTest
@testable import Quip

/// Locks the `iTerm2WriteExpression(for:)` table down. Every entry here maps
/// directly to bytes that get sent into a Claude Code session — silently
/// changing one of these strings would silently break a keystroke type-wide.
final class KeystrokeInjectorWriteExpressionTests: XCTestCase {

    func test_singleByteKeys_returnCharacterIdExpressions() {
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "return"),    "(character id 13)")
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "enter"),     "(character id 13)")
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "escape"),    "(character id 27)")
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "esc"),       "(character id 27)")
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "tab"),       "(character id 9)")
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "backspace"), "(character id 127)")
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "delete"),    "(character id 127)")
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "ctrl+c"),    "(character id 3)")
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "ctrl+d"),    "(character id 4)")
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "ctrl+u"),    "(character id 21)")
    }

    /// Shift+Tab is the standard CSI back-tab sequence — ESC followed by `[Z`.
    /// This is what TUIs (Claude Code, vim, etc.) read as Shift+Tab on a real
    /// keyboard, and the only safe way to drive Claude Code's mode cycle.
    func test_shiftTab_isEscapeBracketZ() {
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "shift+tab"), #"((character id 27) & "[Z")"#)
    }

    func test_caseInsensitive() {
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "RETURN"),    "(character id 13)")
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "Shift+Tab"), #"((character id 27) & "[Z")"#)
    }

    func test_unknownKey_returnsNil() {
        XCTAssertNil(KeystrokeInjector.iTerm2WriteExpression(for: "unknown"))
        XCTAssertNil(KeystrokeInjector.iTerm2WriteExpression(for: ""))
        XCTAssertNil(KeystrokeInjector.iTerm2WriteExpression(for: "f1"))
    }
}
