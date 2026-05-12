import XCTest
@testable import Quip

/// Locks the `KeystrokeInjector.ScrollDirection.iTerm2Keystroke` mapping
/// so a future refactor can't silently flip page-up to page-down or
/// drop a modifier (which would send the keystroke to the running
/// terminal program instead of iTerm's scrollback view). (§38.)
final class Iterm2ScrollKeystrokeTests: XCTestCase {

    func test_pageUp_mapsToShiftPageUp() {
        let (key, mods) = KeystrokeInjector.ScrollDirection.pageUp.iTerm2Keystroke
        XCTAssertEqual(key, 116, "Mac virtual keycode for Page Up is 116")
        XCTAssertEqual(mods, ["shift down"],
                       "iTerm2 default: Shift+PageUp scrolls up one page (PageUp alone goes to the running program)")
    }

    func test_pageDown_mapsToShiftPageDown() {
        let (key, mods) = KeystrokeInjector.ScrollDirection.pageDown.iTerm2Keystroke
        XCTAssertEqual(key, 121, "Mac virtual keycode for Page Down is 121")
        XCTAssertEqual(mods, ["shift down"])
    }

    func test_top_mapsToCmdHome() {
        let (key, mods) = KeystrokeInjector.ScrollDirection.top.iTerm2Keystroke
        XCTAssertEqual(key, 115, "Mac virtual keycode for Home is 115")
        XCTAssertEqual(mods, ["command down"],
                       "iTerm2 default: Cmd+Home scrolls scrollback to the very top")
    }

    func test_bottom_mapsToCmdEnd() {
        let (key, mods) = KeystrokeInjector.ScrollDirection.bottom.iTerm2Keystroke
        XCTAssertEqual(key, 119, "Mac virtual keycode for End is 119")
        XCTAssertEqual(mods, ["command down"],
                       "iTerm2 default: Cmd+End jumps back to the live tail")
    }

    func test_allCases_haveModifiers_neverBareKey() {
        // Bare PageUp/PageDown/Home/End get sent to the running program
        // (less, vim, claude code, etc.) — would scroll the program's
        // buffer, not iTerm's scrollback. Modifier discipline is the
        // whole reason this mapping exists.
        for dir in KeystrokeInjector.ScrollDirection.allCases {
            XCTAssertFalse(dir.iTerm2Keystroke.modifiers.isEmpty,
                           "ScrollDirection.\(dir.rawValue) must include a modifier — bare keys go to the running program")
        }
    }
}
