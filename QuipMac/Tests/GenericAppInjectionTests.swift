import XCTest
@testable import Quip

/// Text and keystrokes aimed at a NON-terminal app (Slack, Xcode, a browser).
///
/// `terminalAppForWindow` answers `.terminal` for every bundle id it doesn't
/// recognize, and `sendText`'s `.terminal` case runs
/// `tell application "Terminal" to activate` + keystroke into
/// `process "Terminal"`. So a dictated transcript aimed at a Slack card was
/// typed into Terminal.app's shell instead — silently, in the wrong app.
/// `isFirstClassHost` is the branch that stops it; these tests pin the branch
/// and the generic script shape.
final class GenericAppInjectionTests: XCTestCase {

    // MARK: - Host classification

    func testTerminalHostsAreFirstClass() {
        for app in TerminalApp.allCases {
            XCTAssertTrue(KeystrokeInjector.isFirstClassHost(bundleId: app.bundleIdentifier),
                          "\(app.rawValue) has its own AppleScript path")
        }
    }

    func testEverythingElseIsGeneric() {
        for bundleId in ["com.tinyspeck.slackmacgap", "com.apple.dt.Xcode",
                         "com.google.Chrome", "com.todesktop.230313mzl4w4u92",
                         "unknown.12345"] {
            XCTAssertFalse(KeystrokeInjector.isFirstClassHost(bundleId: bundleId),
                           "\(bundleId) must take the generic per-pid path")
        }
    }

    // MARK: - Script targeting

    func testGenericScriptTargetsByUnixIDNotByName() {
        // Targeting by name is what makes this class of bug: a process's System
        // Events name is not its app name ("Code" vs "Visual Studio Code"), and
        // a name miss can hit a DIFFERENT app. The pid comes from the CG window
        // list, so it is exactly the process owning the tapped window.
        let script = KeystrokeInjector.genericAppScript(pid: 4321, body: "key code 36")
        XCTAssertTrue(script.contains("every application process whose unix id is 4321"),
                      "must address the process by pid")
        XCTAssertTrue(script.contains("key code 36"))
        XCTAssertFalse(script.contains("tell application \"Terminal\""),
                       "the whole point is that Terminal is not involved")
    }

    func testGenericScriptFailsLoudlyWhenTheProcessIsGone() {
        // A quit app must produce an AppleScript error the phone can surface,
        // not a script that silently succeeds having typed nowhere.
        let script = KeystrokeInjector.genericAppScript(pid: 999, body: "keystroke \"hi\"")
        XCTAssertTrue(script.contains("if quipProcs is {} then error"),
                      "an empty process list has to raise")
    }

    func testGenericScriptRaisesTheTargetBeforeTyping() {
        let script = KeystrokeInjector.genericAppScript(pid: 7, body: "keystroke \"x\"")
        let frontmost = script.range(of: "set frontmost of quipProc to true")
        let typing = script.range(of: "keystroke \"x\"")
        XCTAssertNotNil(frontmost)
        XCTAssertNotNil(typing)
        if let frontmost, let typing {
            XCTAssertTrue(frontmost.lowerBound < typing.lowerBound,
                          "keystrokes go to the focused app — raise first or they land elsewhere")
        }
        XCTAssertTrue(script.contains("delay 0.15"),
                      "the raise needs a beat to propagate before System Events types")
    }

    // MARK: - Key table

    func testSpecialKeysUseVirtualKeyCodes() {
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "return"), "key code 36")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "enter"), "key code 36")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "escape"), "key code 53")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "tab"), "key code 48")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "space"), "key code 49")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "up"), "key code 126")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "down"), "key code 125")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "left"), "key code 123")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "right"), "key code 124")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "backspace"), "key code 51")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "delete"), "key code 51")
    }

    func testModifiedKeysCarryTheirModifier() {
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "shift+tab"),
                       "key code 48 using {shift down}")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "ctrl+c"),
                       "keystroke \"c\" using {control down}")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "ctrl+d"),
                       "keystroke \"d\" using {control down}")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "ctrl+u"),
                       "keystroke \"u\" using {control down}")
    }

    func testKeyNamesAreCaseInsensitive() {
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "RETURN"), "key code 36")
        XCTAssertEqual(KeystrokeInjector.genericKeystrokeCommand(for: "Ctrl+C"),
                       "keystroke \"c\" using {control down}")
    }

    func testUnknownKeyReturnsNilRatherThanKeycodeZero() {
        // nil, not 0: keycode 0 is the `a` key, so an unmapped key would type a
        // stray character into the user's app instead of reporting a failure.
        XCTAssertNil(KeystrokeInjector.genericKeystrokeCommand(for: "f13"))
        XCTAssertNil(KeystrokeInjector.genericKeystrokeCommand(for: ""))
        XCTAssertNil(KeystrokeInjector.genericKeystrokeCommand(for: "cmd+q"),
                     "an unmapped modifier combo must not fall through to a literal")
    }
}
