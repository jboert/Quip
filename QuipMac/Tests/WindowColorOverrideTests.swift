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

    // MARK: - US-009: automatic colors are unique on screen

    private let palette = WindowColor.palette

    private func raw(_ id: String, _ slot: Int) -> WindowManager.RawWindowInfo {
        WindowManager.RawWindowInfo(id: id, name: id, app: "Test", bundleId: "com.test",
                                    pid: 1, windowNumber: CGWindowID(slot + 1),
                                    bounds: CGRect(x: 60 * slot, y: 80, width: 400, height: 300),
                                    spaceID: nil)
    }

    private func window(_ id: String, color: String, enabled: Bool) -> ManagedWindow {
        ManagedWindow(id: id, name: id, app: "Test", subtitle: "",
                      cwdPath: nil, bundleId: "com.test", icon: nil,
                      isEnabled: enabled, assignedColor: color,
                      pid: 1, windowNumber: 1, bounds: .zero,
                      iterm2SessionId: nil, iterm2Tty: nil,
                      isOnVisibleScreen: true)
    }

    private func color(of id: String, in m: WindowManager) -> String? {
        m.windows.first { $0.id == id }?.assignedColor
    }

    func testFiveNewWindowsGetFiveDifferentColors() {
        let m = WindowManager(defaults: defaults)
        m.applyWindowSnapshot((0..<5).map { raw("w\($0)", $0) })
        let colors = m.windows.map(\.assignedColor)
        XCTAssertEqual(colors.count, 5)
        XCTAssertEqual(Set(colors).count, 5, "no two of five windows may share an automatic color")
        XCTAssertTrue(colors.allSatisfy(palette.contains))
    }

    func testANewWindowAvoidsTheColorsAlreadyOnScreen() {
        let m = WindowManager(defaults: defaults)
        m.applyWindowSnapshot([raw("a", 0), raw("b", 1)])
        m.applyWindowSnapshot([raw("a", 0), raw("b", 1), raw("c", 2)])
        let c = color(of: "c", in: m)
        XCTAssertNotNil(c)
        XCTAssertNotEqual(c, color(of: "a", in: m))
        XCTAssertNotEqual(c, color(of: "b", in: m))
    }

    func testAUserPickedColorCountsAsUsed() {
        let m = WindowManager(defaults: defaults)
        m.setColor("picked", hex: palette[0])   // chosen before the window is first seen
        m.applyWindowSnapshot([raw("picked", 0), raw("fresh", 1)])
        XCTAssertEqual(color(of: "picked", in: m), palette[0])
        XCTAssertNotEqual(color(of: "fresh", in: m), palette[0],
                          "a new window must not take the color the user picked for another")
    }

    func testAResetWindowGetsAColorNoOtherWindowHas() {
        let m = WindowManager(defaults: defaults)
        m.windows = (0..<5).map { window("w\($0)", color: palette[$0], enabled: true) }
        m.setColor("w2", hex: "#123456")
        m.setColor("w2", hex: nil)
        let reset = color(of: "w2", in: m)!
        let others = m.windows.filter { $0.id != "w2" }.map(\.assignedColor)
        XCTAssertFalse(others.contains(reset), "reset gave \(reset), already used by another window")
        XCTAssertTrue(palette.contains(reset))
    }

    func testTheEleventhWindowStillGetsAColor() {
        let m = WindowManager(defaults: defaults)
        let ten = (0..<10).map { raw("w\($0)", $0) }
        m.applyWindowSnapshot(ten)
        XCTAssertEqual(Set(m.windows.map(\.assignedColor)).count, 10, "the first ten use the whole palette")
        m.applyWindowSnapshot(ten + [raw("w10", 10)])
        let eleventh = color(of: "w10", in: m)
        XCTAssertNotNil(eleventh)
        XCTAssertTrue(palette.contains(eleventh!), "with all ten taken the rotation still hands out a color")
    }

    /// The owner's list holds dozens of windows, so every palette color is on
    /// screen somewhere. A reset must still not come back as the color of
    /// another ENABLED window, the ones the phone and the preview draw.
    func testWithThePaletteFull_aResetAvoidsTheEnabledWindowsColors() {
        let m = WindowManager(defaults: defaults)
        m.windows = (0..<10).map { window("off\($0)", color: palette[$0], enabled: false) }
            + [window("on0", color: palette[0], enabled: true),
               window("on1", color: palette[1], enabled: true)]
        m.setColor("on1", hex: "#123456")
        m.setColor("on1", hex: nil)
        XCTAssertNotEqual(color(of: "on1", in: m), palette[0],
                          "duplicated the other enabled window's color")
    }

    func testWithThePaletteFull_twoWindowsArrivingTogetherGetDifferentColors() {
        let m = WindowManager(defaults: defaults)
        let ten = (0..<10).map { raw("w\($0)", $0) }
        m.applyWindowSnapshot(ten)
        m.applyWindowSnapshot(ten + [raw("x", 10), raw("y", 11)])
        XCTAssertNotEqual(color(of: "x", in: m), color(of: "y", in: m))
    }

    func testColorsToAvoid_isEveryColorWhileOneIsFree_thenTheShownOnes() {
        let some: Set<String> = [palette[0], palette[1]]
        XCTAssertEqual(WindowManager.colorsToAvoid(all: some, shown: [palette[0]]), some)
        let full = Set(palette)
        XCTAssertEqual(WindowManager.colorsToAvoid(all: full, shown: [palette[3]]), [palette[3]])
        XCTAssertNil(WindowManager.firstUnusedPaletteColor(avoiding: full))
        XCTAssertEqual(WindowManager.firstUnusedPaletteColor(avoiding: [palette[0]]), palette[1])
    }
}
