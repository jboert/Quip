#if os(macOS)
import XCTest
@testable import Quip

/// Regression: every keystroke/send_text delivery waited 80-200ms to let the
/// AX window raise propagate before AppleScript ran. When iTerm2 session-write
/// targets a session directly by UUID, it does NOT need the window to be
/// frontmost — the delay is pure latency the user feels between press and
/// typed character.
final class KeystrokeFocusDelayTests: XCTestCase {

    func testIterm2WithSessionIdNeedsNoDelay() {
        let d = KeystrokeInjector.focusDelay(
            path: .sendText, terminalApp: .iterm2, iterm2SessionId: "UUID-1"
        )
        XCTAssertEqual(d, 0,
                       "iTerm2 session-write bypasses focus; any delay is wasted.")
    }

    func testIterm2WithSessionIdQuickActionAlsoNoDelay() {
        let d = KeystrokeInjector.focusDelay(
            path: .quickAction, terminalApp: .iterm2, iterm2SessionId: "UUID-1"
        )
        XCTAssertEqual(d, 0)
    }

    func testIterm2WithoutSessionIdKeepsSendTextDelay() {
        let d = KeystrokeInjector.focusDelay(
            path: .sendText, terminalApp: .iterm2, iterm2SessionId: nil
        )
        XCTAssertEqual(d, 0.08,
                       "No sessionId → fallback to 'front window' path → need AX raise time.")
    }

    func testIterm2WithoutSessionIdKeepsQuickActionDelay() {
        let d = KeystrokeInjector.focusDelay(
            path: .quickAction, terminalApp: .iterm2, iterm2SessionId: nil
        )
        XCTAssertEqual(d, 0.2,
                       "System Events keystroke races AX raise; 200ms is the proven-safe value.")
    }

    func testTerminalAppAlwaysNeedsDelay() {
        // Terminal.app has no session-id path — sendText and sendKeystroke both
        // go through System Events, which DOES depend on the window being
        // frontmost.
        let sendText = KeystrokeInjector.focusDelay(
            path: .sendText, terminalApp: .terminal, iterm2SessionId: nil
        )
        let quick = KeystrokeInjector.focusDelay(
            path: .quickAction, terminalApp: .terminal, iterm2SessionId: nil
        )
        XCTAssertEqual(sendText, 0.08)
        XCTAssertEqual(quick, 0.2)
    }
}
#endif
