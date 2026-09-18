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

    /// Everything on screen reports just that bucket — announcing a "Hidden"
    /// entry holding nothing would put a chip on the phone that filters to an
    /// empty grid, which is the defect this whole mechanism replaced.
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

    /// The buckets must be named for what `optionOnScreenOnly` actually
    /// measures — whether a window is composited right now — not for a Mission
    /// Control Space.
    ///
    /// They were called "This Desktop" / "Other Desktops", which is a claim
    /// CoreGraphics cannot support: minimizing a window on the desk you are
    /// sitting at drops it from the on-screen list with no Space change at all
    /// (measured: a Finder window flipped on-screen -> off-screen -> on-screen
    /// across a minimize/restore, and a live single-Space desk reported 66 of
    /// its 76 layer-0 windows as being on "other desktops"). The phone defaults
    /// to the first bucket, so the wrong name came with a wrong default: a
    /// minimized terminal's card vanished and the row said it was on another
    /// desktop. Naming the Space needs `CGSCopySpacesForWindows`, which is
    /// private API — so the labels claim only what is measured.
    func testSpaceCatalogNamesBucketsForVisibilityNotForDesktops() {
        let catalog = WindowManager.SpaceCatalog.split(
            allWindows: [1, 2], onCurrentSpace: [1])
        XCTAssertEqual(catalog.spaces.map(\.name), ["On Screen", "Hidden"])
        XCTAssertFalse(catalog.spaces.contains { $0.name.lowercased().contains("desktop") },
                       "a bucket named for a desktop is a claim about Spaces we cannot make")
    }

    /// `desktops(inSnapshot:)` is the path that actually feeds the broadcast —
    /// `split` only stamps ids. Both must agree on the labels or the chips and
    /// the cards describe different things.
    func testSnapshotDerivedBucketsCarryTheSameNamesAsTheSplit() {
        let raw = [
            WindowManager.RawWindowInfo(
                id: "a", name: "a", app: "T", bundleId: "com.t", pid: 1,
                windowNumber: 1, bounds: .zero,
                spaceID: WindowManager.SpaceCatalog.currentSpaceID),
            WindowManager.RawWindowInfo(
                id: "b", name: "b", app: "T", bundleId: "com.t", pid: 1,
                windowNumber: 2, bounds: .zero,
                spaceID: WindowManager.SpaceCatalog.otherSpaceID),
        ]
        XCTAssertEqual(WindowManager.SpaceCatalog.desktops(inSnapshot: raw).map(\.name),
                       ["On Screen", "Hidden"])
    }

    /// Everything missing from the on-screen list lands in the second bucket —
    /// the property the whole split rests on.
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
