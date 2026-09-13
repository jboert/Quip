#if os(macOS)
import XCTest
@testable import Quip

/// Iteration 1 pinned two things the Mac layout UI kept getting wrong:
/// one ordered id list shared by sidebar / preview / arrange, and Arrange
/// targets built in the *selected* display's coordinate space.
@MainActor
final class WindowOrderAndDisplayTests: XCTestCase {

    private func manager(ids: [String]) -> WindowManager {
        let m = WindowManager()
        m.windows = ids.map { id in
            ManagedWindow(id: id, name: id, app: "Test", subtitle: "",
                          cwdPath: nil, bundleId: "com.test", icon: nil,
                          isEnabled: false, assignedColor: "#000000",
                          pid: 1, windowNumber: 1, bounds: .zero,
                          iterm2SessionId: nil, iterm2Tty: nil,
                          isOnVisibleScreen: true)
        }
        m.customOrder = ids
        return m
    }

    // MARK: - setOrder

    func testSetOrderRewritesBothTheOrderAndTheWindowsArray() {
        let m = manager(ids: ["a", "b", "c"])
        m.setOrder(["c", "a", "b"])
        XCTAssertEqual(m.customOrder, ["c", "a", "b"])
        XCTAssertEqual(m.windows.map(\.id), ["c", "a", "b"],
                       "The rendered array must follow the order, not just the id list")
    }

    func testSetOrderAppendsWindowsTheCallerOmitted() {
        let m = manager(ids: ["a", "b", "c"])
        m.setOrder(["b"])
        XCTAssertEqual(m.customOrder, ["b", "a", "c"],
                       "A partial order must not drop the windows it didn't mention")
        XCTAssertEqual(m.windows.count, 3)
    }

    func testSetOrderIgnoresUnknownIDs() {
        let m = manager(ids: ["a", "b"])
        m.setOrder(["ghost", "b", "a"])
        XCTAssertEqual(m.customOrder, ["b", "a"])
        XCTAssertEqual(m.windows.map(\.id), ["b", "a"])
    }

    func testSetOrderIsIdempotent() {
        let m = manager(ids: ["a", "b", "c"])
        m.setOrder(["b", "c", "a"])
        m.setOrder(m.customOrder)
        XCTAssertEqual(m.customOrder, ["b", "c", "a"])
    }

    // MARK: - Display coordinate conversion

    /// The primary display's own frame converts to itself: NS origin (0,0) and
    /// CG origin (0,0) are the same corner. This is the single-display path, so
    /// it must not move by a pixel.
    func testPrimaryDisplayConvertsToItself() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(WindowManager.cgRect(forDisplayFrame: primary, primaryFrame: primary),
                       CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    /// A display sitting to the right and taller than the primary: NS measures
    /// its top edge up from the primary's bottom, CG measures down from the
    /// primary's top, so the y flips sign.
    func testSecondaryDisplayAboveOriginFlipsY() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let secondary = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(WindowManager.cgRect(forDisplayFrame: secondary, primaryFrame: primary),
                       CGRect(x: 1920, y: -360, width: 2560, height: 1440),
                       "A taller secondary extends above the primary's top edge — negative CG y is correct")
    }

    func testSecondaryDisplayBelowPrimary() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let below = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        XCTAssertEqual(WindowManager.cgRect(forDisplayFrame: below, primaryFrame: primary),
                       CGRect(x: 0, y: 1080, width: 1920, height: 1080))
    }

    func testSecondaryDisplayLeftOfPrimaryKeepsNegativeX() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        XCTAssertEqual(WindowManager.cgRect(forDisplayFrame: left, primaryFrame: primary),
                       CGRect(x: -1440, y: 180, width: 1440, height: 900))
    }

    // MARK: - Per-display broadcast frames

    /// The broadcast path normalizes each window against the CG rect of the
    /// display it is on. Passing the *primary* rect for a second-screen window
    /// — what `broadcastLayout` did before — puts x past 1 and the phone's
    /// canvas cannot draw it.
    func testSecondScreenWindowNormalizesInsideItsOwnDisplay() {
        let primaryCG = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let secondaryCG = CGRect(x: 3440, y: 0, width: 2560, height: 1440)
        let terminal = ManagedWindow(
            id: "term", name: "claude", app: "iTerm2", subtitle: "",
            cwdPath: nil, bundleId: "com.googlecode.iterm2", icon: nil,
            isEnabled: true, assignedColor: "#000000",
            pid: 1, windowNumber: 1,
            bounds: CGRect(x: 3600, y: 200, width: 1200, height: 800),
            iterm2SessionId: nil, iterm2Tty: nil,
            isOnVisibleScreen: true, displayID: "display-2")

        let wrong = terminal.toWindowState(screenBounds: primaryCG)
        XCTAssertGreaterThan(wrong.frame.x, 1.0, "the old behavior — off the canvas")

        let right = terminal.toWindowState(screenBounds: secondaryCG)
        XCTAssertEqual(right.frame.x, 160.0 / 2560.0, accuracy: 0.0001)
        XCTAssertEqual(right.frame.y, 200.0 / 1440.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(right.frame.x + right.frame.width, 1.0001)
        XCTAssertEqual(right.displayID, "display-2",
                       "the phone needs the id to know which chip this window belongs to")
    }

    /// A display whose CG rect starts above the primary's top edge has a
    /// negative CG y (see `testSecondaryDisplayAboveOriginFlipsY`). A window on
    /// it must still normalize into 0-1 — subtracting a negative origin is the
    /// step that makes it work, and getting the sign wrong here is invisible on
    /// a single-monitor desk.
    func testWindowOnATallerSecondaryNormalizesIntoRange() {
        let secondaryCG = CGRect(x: 1920, y: -360, width: 2560, height: 1440)
        let window = ManagedWindow(
            id: "w", name: "w", app: "Test", subtitle: "",
            cwdPath: nil, bundleId: "com.test", icon: nil,
            isEnabled: true, assignedColor: "#000000",
            pid: 1, windowNumber: 1,
            bounds: CGRect(x: 2020, y: -260, width: 1000, height: 700),
            iterm2SessionId: nil, iterm2Tty: nil,
            isOnVisibleScreen: true, displayID: "display-2")
        let frame = window.toWindowState(screenBounds: secondaryCG).frame
        XCTAssertEqual(frame.x, 100.0 / 2560.0, accuracy: 0.0001)
        XCTAssertEqual(frame.y, 100.0 / 1440.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(frame.y, 0, "a window above the primary's top edge is still on-canvas")
    }

    // MARK: - SpaceCatalog (current-Space split)

    func testSpaceCatalogSplitsCurrentDesktopFromTheRest() {
        let catalog = WindowManager.SpaceCatalog.split(
            allWindows: [1, 2, 3, 4], onCurrentSpace: [1, 3])
        XCTAssertEqual(catalog.spaces.map(\.id),
                       [WindowManager.SpaceCatalog.currentSpaceID,
                        WindowManager.SpaceCatalog.otherSpaceID])
        XCTAssertEqual(catalog.id(for: 1), WindowManager.SpaceCatalog.currentSpaceID)
        XCTAssertEqual(catalog.id(for: 3), WindowManager.SpaceCatalog.currentSpaceID)
        XCTAssertEqual(catalog.id(for: 2), WindowManager.SpaceCatalog.otherSpaceID)
        XCTAssertEqual(catalog.id(for: 4), WindowManager.SpaceCatalog.otherSpaceID)
    }

    func testSpaceCatalogMarksOnlyTheCurrentDesktopAsCurrent() {
        let catalog = WindowManager.SpaceCatalog.split(
            allWindows: [1, 2], onCurrentSpace: [1])
        XCTAssertEqual(catalog.spaces.first(where: { $0.isCurrent })?.id,
                       WindowManager.SpaceCatalog.currentSpaceID)
        XCTAssertEqual(catalog.spaces.filter(\.isCurrent).count, 1)
    }

    /// Everything on one desktop reports just that desktop — announcing an
    /// "Other Desktops" entry holding nothing would put a chip on the phone
    /// that filters to an empty grid, which is the defect this whole mechanism
    /// replaced.
    func testSpaceCatalogReportsOnlyTheCurrentDesktopWhenNothingIsElsewhere() {
        let catalog = WindowManager.SpaceCatalog.split(
            allWindows: [1, 2], onCurrentSpace: [1, 2])
        XCTAssertEqual(catalog.spaces.map(\.id), [WindowManager.SpaceCatalog.currentSpaceID])
        XCTAssertEqual(catalog.id(for: 1), WindowManager.SpaceCatalog.currentSpaceID)
        XCTAssertEqual(catalog.id(for: 2), WindowManager.SpaceCatalog.currentSpaceID)
    }

    func testSpaceCatalogReportsAnUnknownWindowAsNil() {
        let catalog = WindowManager.SpaceCatalog.split(
            allWindows: [1], onCurrentSpace: [1])
        XCTAssertNil(catalog.id(for: 99))
    }

    /// The window ids CoreGraphics hands back for other Spaces are exactly the
    /// ones missing from the on-screen list — the property the whole split
    /// rests on.
    func testSpaceCatalogTreatsEveryWindowMissingFromOnScreenAsElsewhere() {
        let catalog = WindowManager.SpaceCatalog.split(
            allWindows: [10, 20, 30], onCurrentSpace: [])
        XCTAssertEqual(catalog.spaces.map(\.id), [WindowManager.SpaceCatalog.otherSpaceID])
        for id in [10, 20, 30] {
            XCTAssertEqual(catalog.id(for: CGWindowID(id)),
                           WindowManager.SpaceCatalog.otherSpaceID)
        }
    }
}

#endif
