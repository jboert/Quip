import XCTest
@testable import Quip

/// A color chosen on the phone lives on the Mac, survives a relaunch, and is
/// what every peer is sent.
@MainActor
final class WindowColorOverrideTests: XCTestCase {

    private var savedOverrides: Any?

    override func setUp() {
        super.setUp()
        // The test host is the app itself: keep the owner's real choices.
        savedOverrides = UserDefaults.standard.object(forKey: WindowManager.colorOverridesKey)
        UserDefaults.standard.removeObject(forKey: WindowManager.colorOverridesKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedOverrides, forKey: WindowManager.colorOverridesKey)
        super.tearDown()
    }

    private func manager(ids: [String]) -> WindowManager {
        let m = WindowManager()
        m.windows = ids.map { id in
            ManagedWindow(id: id, name: id, app: "Test", subtitle: "",
                          cwdPath: nil, bundleId: "com.test", icon: nil,
                          isEnabled: true, assignedColor: "#000000",
                          pid: 1, windowNumber: 1, bounds: .zero,
                          iterm2SessionId: nil, iterm2Tty: nil,
                          isOnVisibleScreen: true)
        }
        return m
    }

    func testSetColorRecolorsTheWindowAndOnlyThatWindow() {
        let m = manager(ids: ["a", "b"])
        m.setColor("a", hex: "#4a90d9")
        XCTAssertEqual(m.windows[0].assignedColor, "#4A90D9")
        XCTAssertEqual(m.windows[1].assignedColor, "#000000")
        XCTAssertEqual(m.windows[0].toWindowState(screenBounds: .zero).color, "#4A90D9")
    }

    func testChoiceSurvivesANewManager() {
        manager(ids: ["a"]).setColor("a", hex: "#FF6B6B")
        XCTAssertEqual(WindowManager().colorOverrides["a"], "#FF6B6B")
    }

    func testResetDropsTheChoiceAndGivesAPaletteColor() {
        let m = manager(ids: ["a"])
        m.setColor("a", hex: "#123456")
        m.setColor("a", hex: nil)
        XCTAssertNil(m.colorOverrides["a"])
        XCTAssertTrue(WindowColor.palette.contains(m.windows[0].assignedColor))
        XCTAssertNil(WindowManager().colorOverrides["a"])
    }

    func testMalformedColorIsIgnored() {
        let m = manager(ids: ["a"])
        m.setColor("a", hex: "blue")
        XCTAssertEqual(m.windows[0].assignedColor, "#000000")
        XCTAssertTrue(m.colorOverrides.isEmpty)
    }
}
