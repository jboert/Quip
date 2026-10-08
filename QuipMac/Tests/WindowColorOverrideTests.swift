import XCTest
@testable import Quip

@MainActor
final class WindowColorOverrideTests: XCTestCase {

    // The manager persists to this suite, never the owner's com.quip.mac domain
    // (this file used to remove and rewrite the real windowColorOverrides).
    private static let suiteName = "com.quip.mac.tests.window-colors"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = TestSafeDefaults.suite("window-colors")
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        super.tearDown()
    }

    private func manager(ids: [String]) -> WindowManager {
        let m = WindowManager(defaults: defaults)
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
        XCTAssertEqual(WindowManager(defaults: defaults).colorOverrides["a"], "#FF6B6B")
    }

    func testResetDropsTheChoiceAndGivesAPaletteColor() {
        let m = manager(ids: ["a"])
        m.setColor("a", hex: "#123456")
        m.setColor("a", hex: nil)
        XCTAssertNil(m.colorOverrides["a"])
        XCTAssertTrue(WindowColor.palette.contains(m.windows[0].assignedColor))
        XCTAssertNil(WindowManager(defaults: defaults).colorOverrides["a"])
    }

    func testMalformedColorIsIgnored() {
        let m = manager(ids: ["a"])
        m.setColor("a", hex: "blue")
        XCTAssertEqual(m.windows[0].assignedColor, "#000000")
        XCTAssertTrue(m.colorOverrides.isEmpty)
    }

    func testManagerWithoutAnExplicitStoreStaysOutOfTheOwnersDomain() {
        XCTAssertTrue(SingleInstanceGuard.isRunningTests)
        XCTAssertFalse(WindowManager.defaultStore === UserDefaults.standard,
                       "WindowManager() in a test must not read or write com.quip.mac")
    }
}
