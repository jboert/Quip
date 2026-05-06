import XCTest
@testable import Quip

/// Locks the AppleScript shape that `KeystrokeInjector.pasteText` ships
/// for Codex CLI windows. The script walks window→tab→session, selects
/// the target session by unique id, activates iTerm2, and Cmd+V's the
/// clipboard. With pressReturn=true an extra Enter (key code 36) follows.
///
/// Pinned because Codex's interactive composer ignores PTY-typed bytes
/// from `write text` (the path `sendText` uses) — a future refactor that
/// silently degrades to a "write text" verb here would re-break PTT
/// transcripts to Codex windows. (Story I follow-up.)
final class PasteTextScriptTests: XCTestCase {

    func test_includesSessionLookupByUniqueId() {
        let script = KeystrokeInjector.pasteTextScript(iterm2SessionId: "ABCD-1234", pressReturn: false)
        XCTAssertTrue(script.contains("if unique id of aSession is \"ABCD-1234\""),
                      "must walk every session checking unique id, no front-window fallback")
    }

    func test_walksWindowTabSessionHierarchy() {
        let script = KeystrokeInjector.pasteTextScript(iterm2SessionId: "X", pressReturn: false)
        XCTAssertTrue(script.contains("repeat with aWindow in windows"))
        XCTAssertTrue(script.contains("repeat with aTab in tabs"))
        XCTAssertTrue(script.contains("repeat with aSession in sessions"))
    }

    func test_selectsTargetSessionBeforeActivating() {
        let script = KeystrokeInjector.pasteTextScript(iterm2SessionId: "X", pressReturn: false)
        guard let selectIdx = script.range(of: "select aSession"),
              let activateIdx = script.range(of: "activate") else {
            XCTFail("script missing select aSession or activate"); return
        }
        XCTAssertLessThan(selectIdx.lowerBound, activateIdx.lowerBound,
                          "select session must precede activate so Cmd+V lands in the right pane")
    }

    func test_pressReturnFalse_omitsEnterKeystroke() {
        let script = KeystrokeInjector.pasteTextScript(iterm2SessionId: "X", pressReturn: false)
        XCTAssertFalse(script.contains("key code 36"),
                       "no Return when pressReturn=false (paste-only)")
    }

    func test_pressReturnTrue_appendsEnterKeystroke() {
        let script = KeystrokeInjector.pasteTextScript(iterm2SessionId: "X", pressReturn: true)
        XCTAssertTrue(script.contains("key code 36"),
                      "Return (key code 36) submits the pasted text in Codex's composer")
    }

    func test_alwaysSendsCmdV() {
        let withReturn = KeystrokeInjector.pasteTextScript(iterm2SessionId: "X", pressReturn: true)
        let withoutReturn = KeystrokeInjector.pasteTextScript(iterm2SessionId: "X", pressReturn: false)
        XCTAssertTrue(withReturn.contains("keystroke \"v\" using command down"))
        XCTAssertTrue(withoutReturn.contains("keystroke \"v\" using command down"))
    }

    func test_sessionIdIsAppleScriptEscaped() {
        // A session id with a literal backslash + quote pair must not
        // break out of the AppleScript string literal — that would
        // produce an invalid script and silently fail with a "syntax
        // error" runtime exception. Escape both.
        let script = KeystrokeInjector.pasteTextScript(
            iterm2SessionId: "a\\b\"c", pressReturn: false
        )
        XCTAssertTrue(script.contains("a\\\\b\\\"c"),
                      "backslashes must double, double-quotes must backslash-escape")
    }

    func test_errorsLoudlyWhenSessionNotFound() {
        // The error verb in AppleScript surfaces as a non-zero
        // executeAppleScript exit, which the InjectionResult logs.
        // Without this branch, `quipFound = false` would silently
        // exit and Cmd+V would land in whatever pane is frontmost.
        let script = KeystrokeInjector.pasteTextScript(iterm2SessionId: "missing", pressReturn: false)
        XCTAssertTrue(script.contains("error \"Quip: iTerm2 session missing not found\""))
    }

    func test_systemEventsCmdVTargetsITerm2Process() {
        // Cmd+V must be sent to the iTerm2 process specifically, not
        // the frontmost app — System Events `tell process "iTerm2"`
        // ensures the keystroke routes there even if focus drifted.
        let script = KeystrokeInjector.pasteTextScript(iterm2SessionId: "X", pressReturn: false)
        XCTAssertTrue(script.contains("tell process \"iTerm2\""))
    }
}
