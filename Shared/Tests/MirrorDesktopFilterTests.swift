#if os(macOS)
import XCTest
import CoreGraphics
@testable import Quip

/// The mirror-desktop setting lets the phone see every terminal window the Mac
/// tracks, not just the ones Quip has been told to "enable". These tests pin
/// down the filter used by broadcastLayout so a regression here can't silently
/// expose arbitrary windows or hide terminals the user expected to see.
@MainActor
final class MirrorDesktopFilterTests: XCTestCase {

    private func mw(
        id: String,
        bundleId: String,
        enabled: Bool,
        onVisibleScreen: Bool = true
    ) -> ManagedWindow {
        ManagedWindow(
            id: id,
            name: id,
            app: bundleId,
            subtitle: "",
            bundleId: bundleId,
            icon: nil,
            isEnabled: enabled,
            assignedColor: "#F5A623",
            pid: 1,
            windowNumber: 0,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            iterm2SessionId: nil,
            isOnVisibleScreen: onVisibleScreen
        )
    }

    // Two terminal bundles (iTerm2 + Terminal.app) and one non-terminal
    // (a browser) — the realistic mix on a dev machine.
    private let iterm2 = "com.googlecode.iterm2"
    private let terminal = "com.apple.Terminal"
    private let browser = "com.apple.Safari"

    func testMirrorOffShowsOnlyEnabledWindows() {
        let all = [
            mw(id: "a", bundleId: iterm2, enabled: true),
            mw(id: "b", bundleId: iterm2, enabled: false),
            mw(id: "c", bundleId: browser, enabled: true),
        ]
        let ids = WindowManager.windowsForBroadcast(all, mirrorDesktop: false).map(\.id)
        XCTAssertEqual(Set(ids), Set(["a", "c"]),
                       "Off: every enabled window (terminal or not) is visible.")
    }

    func testMirrorOnShowsAllTerminalsPlusEnabledNonTerminals() {
        let all = [
            mw(id: "a", bundleId: iterm2, enabled: true),
            mw(id: "b", bundleId: iterm2, enabled: false),
            mw(id: "c", bundleId: terminal, enabled: false),
            mw(id: "d", bundleId: browser, enabled: false),
            mw(id: "e", bundleId: browser, enabled: true),
        ]
        let ids = WindowManager.windowsForBroadcast(all, mirrorDesktop: true).map(\.id)
        XCTAssertEqual(Set(ids), Set(["a", "b", "c", "e"]),
                       "On: every terminal window appears, plus any enabled non-terminal the user already activated.")
        XCTAssertFalse(ids.contains("d"),
                       "Mirror mode is 'terminals only' — non-terminal windows without enable don't leak.")
    }

    func testMirrorOnWithNoTerminalsStillShowsEnabledNonTerminals() {
        let all = [mw(id: "x", bundleId: browser, enabled: true)]
        let ids = WindowManager.windowsForBroadcast(all, mirrorDesktop: true).map(\.id)
        XCTAssertEqual(ids, ["x"])
    }
}
#endif
