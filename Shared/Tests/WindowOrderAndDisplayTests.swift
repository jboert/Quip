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
}
#endif
