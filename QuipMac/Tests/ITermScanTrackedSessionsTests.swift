import XCTest
@testable import Quip

/// US-011: the iTerm scan reports a session as tracked when its window is an
/// enabled, mapped iTerm2 window OR the user attached it. Before, only the
/// first counted, so a window attached moments ago (its mapping and enable
/// still pending) or attached before a phone relaunch came back as attachable.
final class ITermScanTrackedSessionsTests: XCTestCase {

    private let iterm = TerminalApp.iterm2.bundleIdentifier

    private func window(_ id: String, bundleId: String, enabled: Bool, session: String?) -> ManagedWindow {
        ManagedWindow(id: id, name: id, app: "Test", subtitle: "",
                      cwdPath: nil, bundleId: bundleId, icon: nil,
                      isEnabled: enabled, assignedColor: "#000000",
                      pid: 1, windowNumber: 1, bounds: .zero,
                      iterm2SessionId: session, iterm2Tty: nil,
                      isOnVisibleScreen: true)
    }

    func test_enabledMappedITermWindow_isTracked() {
        let tracked = WindowManager.trackedITermSessionIds(
            windows: [window("w1", bundleId: iterm, enabled: true, session: "S1")],
            attached: [])
        XCTAssertEqual(tracked, ["S1"])
    }

    func test_disabledMappedWindow_isNotTrackedUnlessAttached() {
        let windows = [window("w1", bundleId: iterm, enabled: false, session: "S1")]
        XCTAssertEqual(WindowManager.trackedITermSessionIds(windows: windows, attached: []), [])
        XCTAssertEqual(WindowManager.trackedITermSessionIds(windows: windows, attached: ["S1"]), ["S1"])
    }

    func test_attachedSessionWithNoMappedWindowYet_isTracked() {
        // The attach landed, but the session-map pass that maps and enables the
        // window has not run: the window has no session id yet.
        let tracked = WindowManager.trackedITermSessionIds(
            windows: [window("w1", bundleId: iterm, enabled: false, session: nil)],
            attached: ["S-JUST-ATTACHED"])
        XCTAssertEqual(tracked, ["S-JUST-ATTACHED"])
    }

    func test_resultIsTheUnionOfBoth() {
        let tracked = WindowManager.trackedITermSessionIds(
            windows: [
                window("w1", bundleId: iterm, enabled: true, session: "S1"),
                window("w2", bundleId: iterm, enabled: true, session: "S2"),
                window("w3", bundleId: iterm, enabled: false, session: "S3"),
            ],
            attached: ["S2", "S4"])
        XCTAssertEqual(tracked, ["S1", "S2", "S4"])
    }

    func test_nonITermWindowsContributeNothing() {
        let tracked = WindowManager.trackedITermSessionIds(
            windows: [window("w1", bundleId: TerminalApp.terminal.bundleIdentifier, enabled: true, session: "S1")],
            attached: [])
        XCTAssertEqual(tracked, [])
    }
}
