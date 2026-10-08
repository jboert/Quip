import XCTest
@testable import Quip

/// US-116: a broadcast does not raise iTerm2 windows, and Terminal.app
/// keystrokes never land in another window.
final class WindowRaisePolicyTests: XCTestCase {

    func test_noRequestRaisesEverywhere() {
        for term in TerminalApp.allCases {
            for generic in [false, true] {
                XCTAssertTrue(WindowRaisePolicy.shouldRaise(requested: nil, terminalApp: term, isGenericApp: generic),
                              "\(term) generic=\(generic)")
                XCTAssertTrue(WindowRaisePolicy.shouldRaise(requested: true, terminalApp: term, isGenericApp: generic),
                              "\(term) generic=\(generic)")
            }
        }
    }

    func test_aQuietRequestSkipsTheRaiseOnlyForITerm2() {
        XCTAssertFalse(WindowRaisePolicy.shouldRaise(requested: false, terminalApp: .iterm2, isGenericApp: false))
        XCTAssertTrue(WindowRaisePolicy.shouldRaise(requested: false, terminalApp: .terminal, isGenericApp: false),
                      "without a window number the script cannot raise the window itself")
        XCTAssertFalse(WindowRaisePolicy.shouldRaise(requested: false, terminalApp: .terminal, isGenericApp: false,
                                                     cgWindowNumber: 4242),
                       "the Terminal.app script raises and verifies window 4242 on the serial queue")
        XCTAssertTrue(WindowRaisePolicy.shouldRaise(requested: nil, terminalApp: .terminal, isGenericApp: false,
                                                    cgWindowNumber: 4242),
                      "a single tap keeps the Accessibility raise as belt and braces")
        XCTAssertTrue(WindowRaisePolicy.shouldRaise(requested: false, terminalApp: .claudeDesktop, isGenericApp: false))
        XCTAssertTrue(WindowRaisePolicy.shouldRaise(requested: false, terminalApp: .iterm2, isGenericApp: true),
                      "a generic app is pasted into as the active app, whatever terminalAppForWindow guessed")
    }
}

/// A prompt's `{{clipboard}}` in a broadcast reads the user's text, never an
/// earlier target's pasted body.
final class ClipboardForTemplateTests: XCTestCase {

    func test_liveClipboardWhenNoPasteIsInFlight() {
        XCTAssertEqual(KeystrokeInjector.clipboardForTemplate(outstanding: 0, original: "stale") { "live" }, "live")
    }

    func test_burstSnapshotWhileAPasteHoldsThePasteboard() {
        var liveReads = 0
        let value = KeystrokeInjector.clipboardForTemplate(outstanding: 2, original: "the user's text") {
            liveReads += 1
            return "Review this: the user's text"
        }
        XCTAssertEqual(value, "the user's text")
        XCTAssertEqual(liveReads, 0, "the pasteboard is not read while it holds an injected body")
    }

    func test_anEmptySnapshotStaysEmpty() {
        XCTAssertNil(KeystrokeInjector.clipboardForTemplate(outstanding: 1, original: nil) { "injected" })
    }
}

/// US-115: every injection answers with an ack or an error that names the
/// request it belongs to.
final class InjectionReplyTests: XCTestCase {
    private let id = UUID()

    func test_aSuccessProducesOneAckWithTheRequestsId() {
        let replies = InjectionReply.messages(result: .init(success: true, error: nil), messageId: id,
                                              injectMs: 12, totalMs: 40, path: "sendText", failurePrefix: "Prompt paste failed")
        XCTAssertEqual(replies.ack, SendTextAckMessage(messageId: id, injectMs: 12, totalMs: 40, path: "sendText"))
        XCTAssertNil(replies.error)
    }

    func test_aFailureProducesOneErrorWithTheRequestsId() {
        let replies = InjectionReply.messages(result: .init(success: false, error: "iTerm2 session not found"), messageId: id,
                                              injectMs: 1, totalMs: 2, path: "pasteText", failurePrefix: "Text send failed")
        XCTAssertNil(replies.ack)
        XCTAssertEqual(replies.error, ErrorMessage(reason: "Text send failed: iTerm2 session not found", messageId: id))
    }

    func test_aRequestWithoutAnIdGetsNoAckButStillTheError() {
        let ok = InjectionReply.messages(result: .init(success: true, error: nil), messageId: nil,
                                         injectMs: 1, totalMs: 2, path: "sendText", failurePrefix: "x")
        XCTAssertEqual(ok, InjectionReply.Messages())
        let bad = InjectionReply.messages(result: .init(success: false, error: nil), messageId: nil,
                                          injectMs: 1, totalMs: 2, path: "sendText", failurePrefix: "Text send failed")
        XCTAssertEqual(bad.error, ErrorMessage(reason: "Text send failed: unknown injection failure", messageId: nil))
    }
}

/// US-116: the Terminal.app scripts raise their own window and refuse to
/// type when another window is in front. The raise and the keystrokes run
/// in one script on the serial AppleScript queue, so two broadcast targets
/// cannot interleave a raise of one with the keystrokes of the other.
final class TerminalWindowGuardTests: XCTestCase {

    func test_pasteScriptWithAWindowNumberRaisesAndVerifiesItBeforeCmdV() {
        let script = KeystrokeInjector.terminalPasteTextScript(pressReturn: false, windowNumber: 968)
        XCTAssertTrue(script.contains("set frontmost of window id 968 to true"))
        XCTAssertTrue(script.contains("if id of front window is not 968 then error"))
        XCTAssertTrue(script.contains("if not (exists window id 968) then error"))
        guard let verify = script.range(of: "id of front window is not 968"),
              let paste = script.range(of: "keystroke \"v\" using command down") else {
            return XCTFail("script missing the guard or Cmd+V")
        }
        XCTAssertLessThan(verify.lowerBound, paste.lowerBound, "verify before typing")
    }

    func test_withoutAWindowNumberTheScriptIsTodays() {
        let script = KeystrokeInjector.terminalPasteTextScript(pressReturn: false)
        XCTAssertFalse(script.contains("window id"))
        XCTAssertEqual(script, KeystrokeInjector.terminalPasteTextScript(pressReturn: false, windowNumber: 0))
    }

    func test_keystrokeScriptCarriesTheSameGuard() {
        let script = KeystrokeInjector.terminalKeystrokeScript(commands: ["keystroke \"ls\"", "key code 36"], windowNumber: 72)
        XCTAssertTrue(script.contains("set frontmost of window id 72 to true"))
        XCTAssertTrue(script.contains("if id of front window is not 72 then error"))
        guard let verify = script.range(of: "id of front window is not 72"),
              let type = script.range(of: "keystroke \"ls\"") else {
            return XCTFail("script missing the guard or the keystrokes")
        }
        XCTAssertLessThan(verify.lowerBound, type.lowerBound)
        XCTAssertFalse(KeystrokeInjector.terminalKeystrokeScript(commands: ["key code 36"], windowNumber: 0).contains("window id"))
    }
}
