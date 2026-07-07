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
    func test_arrowKeys_areCSISequences() {
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "up"),    #"((character id 27) & "[A")"#)
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "down"),  #"((character id 27) & "[B")"#)
        // Right-arrow accepts the inline autocomplete suggestion.
        XCTAssertEqual(KeystrokeInjector.iTerm2WriteExpression(for: "right"), #"((character id 27) & "[C")"#)
    }

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

    // MARK: - keyCodeFor (System Events / Terminal.app path, review M1)
    //
    // Locks the macOS virtual keycodes used on the System Events keystroke path.
    // A transposed code here would silently inject the wrong key on Terminal.app
    // windows (arrow navigation / accept-autocomplete), so pin every entry.

    func test_keyCodeFor_mappedKeys() {
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("return"), 36)
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("enter"),  36)
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("escape"), 53)
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("esc"),    53)
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("tab"),    48)
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("delete"), 51)
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("space"),  49)
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("down"),   125)
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("up"),     126)
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("right"),  124)
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("left"),   123)
    }

    func test_keyCodeFor_caseInsensitive() {
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("RIGHT"), 124)
        XCTAssertEqual(KeystrokeInjector.keyCodeFor("Up"),    126)
    }

    /// nil (not 0) for an unmapped key — 0 is the `a` keycode, so a silent
    /// fallback would type `a` instead of the intended special key. (review M1)
    func test_keyCodeFor_unmappedReturnsNil() {
        XCTAssertNil(KeystrokeInjector.keyCodeFor("f1"))
        XCTAssertNil(KeystrokeInjector.keyCodeFor("home"))
        XCTAssertNil(KeystrokeInjector.keyCodeFor(""))
    }
}
