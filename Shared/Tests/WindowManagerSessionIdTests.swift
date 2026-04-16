#if os(macOS)
import XCTest
import CoreGraphics
@testable import Quip

/// Regression: iTerm2 windows with duplicate titles used to collapse onto a
/// single sessionId, silently routing all text/keystrokes to one window.
/// Keying the map by window bounds instead of title disambiguates them.
@MainActor
final class WindowManagerSessionIdTests: XCTestCase {

    private func makeIterm2Window(id: String, name: String, windowNumber: CGWindowID, bounds: CGRect) -> ManagedWindow {
        ManagedWindow(
            id: id,
            name: name,
            app: "iTerm2",
            subtitle: "",
            bundleId: "com.googlecode.iterm2",
            icon: nil,
            isEnabled: true,
            assignedColor: "#F5A623",
            pid: 1,
            windowNumber: windowNumber,
            bounds: bounds,
            iterm2SessionId: nil
        )
    }

    func testApplySessionIdsDisambiguatesWindowsWithDuplicateTitles() {
        let wm = WindowManager()
        let boundsA = CGRect(x: 0, y: 0, width: 800, height: 600)
        let boundsB = CGRect(x: 900, y: 0, width: 800, height: 600)

        wm.windows = [
            makeIterm2Window(id: "com.googlecode.iterm2.101",
                             name: "claude — ~/Projects/Quip",
                             windowNumber: 101, bounds: boundsA),
            makeIterm2Window(id: "com.googlecode.iterm2.102",
                             name: "claude — ~/Projects/Quip",
                             windowNumber: 102, bounds: boundsB)
        ]

        wm.applyIterm2SessionIds([
            WindowManager.Iterm2SessionInfo(bounds: boundsA, uuid: "UUID-A"),
            WindowManager.Iterm2SessionInfo(bounds: boundsB, uuid: "UUID-B")
        ])

        XCTAssertEqual(wm.windows[0].iterm2SessionId, "UUID-A",
                       "Window at boundsA must get UUID-A even though title collides")
        XCTAssertEqual(wm.windows[1].iterm2SessionId, "UUID-B",
                       "Window at boundsB must get UUID-B — title is identical to window A")
    }

    func testApplySessionIdsSkipsUnmatchedWindows() {
        let wm = WindowManager()
        let boundsInList = CGRect(x: 0, y: 0, width: 800, height: 600)
        let boundsOrphan = CGRect(x: 10_000, y: 10_000, width: 800, height: 600)

        wm.windows = [
            makeIterm2Window(id: "com.googlecode.iterm2.999",
                             name: "orphan",
                             windowNumber: 999, bounds: boundsOrphan)
        ]

        wm.applyIterm2SessionIds([
            WindowManager.Iterm2SessionInfo(bounds: boundsInList, uuid: "UUID-X")
        ])

        XCTAssertNil(wm.windows[0].iterm2SessionId,
                     "A window far from every known session must not inherit a random UUID")
    }

    func testNeedsIterm2SessionIdRefreshFlagsNewWindows() {
        let wm = WindowManager()
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

        var withId = makeIterm2Window(id: "com.googlecode.iterm2.10",
                                      name: "a", windowNumber: 10, bounds: bounds)
        withId.iterm2SessionId = "UUID-ALREADY-SET"
        wm.windows = [withId]
        XCTAssertFalse(wm.needsIterm2SessionIdRefresh,
                       "No refresh needed when every iTerm2 window already has a UUID")

        wm.windows.append(makeIterm2Window(id: "com.googlecode.iterm2.11",
                                           name: "b", windowNumber: 11, bounds: bounds))
        XCTAssertTrue(wm.needsIterm2SessionIdRefresh,
                      "A freshly-discovered iTerm2 window with nil UUID must trigger a refresh")
    }

    func testNeedsIterm2SessionIdRefreshIgnoresNonIterm2Windows() {
        let wm = WindowManager()
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        // A Terminal.app window legitimately has no iterm2SessionId — it must
        // not drag us into refreshing iTerm2 session IDs every tick.
        var terminalWindow = makeIterm2Window(id: "com.apple.Terminal.5",
                                              name: "bash",
                                              windowNumber: 5,
                                              bounds: bounds)
        let mirrored = ManagedWindow(
            id: terminalWindow.id,
            name: terminalWindow.name,
            app: "Terminal",
            subtitle: terminalWindow.subtitle,
            bundleId: "com.apple.Terminal",
            icon: nil,
            isEnabled: true,
            assignedColor: terminalWindow.assignedColor,
            pid: terminalWindow.pid,
            windowNumber: terminalWindow.windowNumber,
            bounds: terminalWindow.bounds,
            iterm2SessionId: nil
        )
        _ = terminalWindow // silence unused
        wm.windows = [mirrored]
        XCTAssertFalse(wm.needsIterm2SessionIdRefresh,
                       "Terminal.app windows legitimately have nil iterm2SessionId")
    }

    func testApplySessionIdsHandlesMinorBoundsDrift() {
        // iTerm2 AppleScript bounds and CG window bounds can differ by a few pixels
        // (title bar, shadow). Matching must tolerate that drift.
        let wm = WindowManager()
        let cgBounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let applescriptBounds = CGRect(x: 103, y: 98, width: 800, height: 600)

        wm.windows = [
            makeIterm2Window(id: "com.googlecode.iterm2.42",
                             name: "w", windowNumber: 42, bounds: cgBounds)
        ]

        wm.applyIterm2SessionIds([
            WindowManager.Iterm2SessionInfo(bounds: applescriptBounds, uuid: "UUID-CLOSE")
        ])

        XCTAssertEqual(wm.windows[0].iterm2SessionId, "UUID-CLOSE",
                       "Bounds within a few pixels should still match")
    }
}
#endif
