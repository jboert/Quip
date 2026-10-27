import XCTest
@testable import Quip

/// A window the user enabled comes back enabled after a Quip relaunch or
/// reinstall, within one boot. Live evidence 2026-10-27: with "Mirror desktop
/// terminals" off, every relaunch sent the phone an empty layout ("No
/// windows") because the enabled flag lived only in memory.
@MainActor
final class WindowEnabledMemoryTests: XCTestCase {

    private static let suiteName = "com.quip.mac.tests.window-enabled"
    private var defaults: UserDefaults!
    private let boot = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        defaults = TestSafeDefaults.suite("window-enabled")
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        super.tearDown()
    }

    private func manager(bootTime: Date? = nil) -> WindowManager {
        WindowManager(defaults: defaults, clock: Date.init, bootTime: bootTime ?? boot)
    }

    private func raw(_ id: String, _ slot: Int) -> WindowManager.RawWindowInfo {
        WindowManager.RawWindowInfo(id: id, name: "title-\(id)", app: "Test", bundleId: "com.test",
                                    pid: 1, windowNumber: CGWindowID(slot + 1),
                                    bounds: CGRect(x: 60 * slot, y: 80, width: 400, height: 300),
                                    spaceID: nil)
    }

    private func snapshot(_ ids: [String]) -> [WindowManager.RawWindowInfo] {
        ids.enumerated().map { raw($1, $0) }
    }

    private func enabledIDs(in m: WindowManager) -> Set<String> {
        Set(m.windows.filter(\.isEnabled).map(\.id))
    }

    func testEnabledWindowComesBackEnabledAfterRelaunch() {
        let first = manager()
        first.applyWindowSnapshot(snapshot(["A", "B", "C"]))
        first.toggleWindow("B", enabled: true)
        XCTAssertEqual(enabledIDs(in: first), ["B"])

        let relaunched = manager()
        relaunched.applyWindowSnapshot(snapshot(["A", "B", "C"]))
        XCTAssertEqual(enabledIDs(in: relaunched), ["B"])
    }

    func testDisablingForgetsTheWindow() {
        let first = manager()
        first.applyWindowSnapshot(snapshot(["A", "B"]))
        first.toggleWindow("A", enabled: true)
        first.toggleWindow("A", enabled: false)

        let relaunched = manager()
        relaunched.applyWindowSnapshot(snapshot(["A", "B"]))
        XCTAssertEqual(enabledIDs(in: relaunched), [])
    }

    func testMemoryDoesNotOutliveAReboot() {
        let first = manager()
        first.applyWindowSnapshot(snapshot(["A"]))
        first.toggleWindow("A", enabled: true)

        let afterReboot = manager(bootTime: boot.addingTimeInterval(3600))
        afterReboot.applyWindowSnapshot(snapshot(["A"]))
        XCTAssertEqual(enabledIDs(in: afterReboot), [])
    }

    func testMemorySurvivesAClockJitterSmallerThanTheTolerance() {
        let first = manager()
        first.applyWindowSnapshot(snapshot(["A"]))
        first.toggleWindow("A", enabled: true)

        let relaunched = manager(bootTime: boot.addingTimeInterval(WindowManager.bootTimeTolerance))
        relaunched.applyWindowSnapshot(snapshot(["A"]))
        XCTAssertEqual(enabledIDs(in: relaunched), ["A"])
    }

    /// Two windows enabled before the relaunch that were dealt the same color
    /// (eleven windows, palette of ten) come back in different colors.
    func testRestoredEnabledWindowsAreKeptApartInColor() {
        let ids = (0..<11).map { "w\($0)" }
        let first = manager()
        first.applyWindowSnapshot(snapshot(ids))
        first.toggleWindow("w0", enabled: true)
        first.toggleWindow("w10", enabled: true)

        let relaunched = manager()
        relaunched.applyWindowSnapshot(snapshot(ids))
        XCTAssertEqual(enabledIDs(in: relaunched), ["w0", "w10"])
        let colors = relaunched.windows.filter(\.isEnabled).map(\.assignedColor)
        XCTAssertEqual(Set(colors).count, colors.count, "enabled windows share a color: \(colors)")
    }

    func testPruneKeepsTheMostRecentlyEnabled() {
        let base = Date(timeIntervalSince1970: 1_000)
        let ids: [String: Date] = ["old": base, "mid": base.addingTimeInterval(1),
                                   "new": base.addingTimeInterval(2)]
        let pruned = WindowManager.prunedEnabledWindowIDs(ids, maxCount: 2)
        XCTAssertEqual(Set(pruned.keys), ["mid", "new"])
    }
}
