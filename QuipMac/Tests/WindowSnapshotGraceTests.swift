import XCTest
@testable import Quip

/// US-010: a window keeps its automatic color, list slot, enabled flag and
/// iTerm2 session through a short absence from the snapshot and across a Mac
/// restart. Live evidence 2026-10-07: one iTerm2 window missed a single 2 s
/// snapshot while the owner closed others, and came back at the end of the
/// list, disabled, in another window's color.
@MainActor
final class WindowSnapshotGraceTests: XCTestCase {

    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private static let suiteName = "com.quip.mac.tests.window-grace"
    private var defaults: UserDefaults!
    private var clock: TestClock!

    override func setUp() {
        super.setUp()
        defaults = TestSafeDefaults.suite("window-grace")
        defaults.removePersistentDomain(forName: Self.suiteName)
        clock = TestClock()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        clock = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func manager() -> WindowManager {
        let clock = self.clock!
        return WindowManager(defaults: defaults, clock: { clock.now })
    }

    private func raw(_ id: String, _ slot: Int, bundleId: String = "com.test") -> WindowManager.RawWindowInfo {
        WindowManager.RawWindowInfo(id: id, name: "title-\(id)", app: "Test", bundleId: bundleId,
                                    pid: 1, windowNumber: CGWindowID(slot + 1),
                                    bounds: CGRect(x: 60 * slot, y: 80, width: 400, height: 300),
                                    spaceID: nil)
    }

    private func snapshot(_ ids: [String], bundleId: String = "com.test") -> [WindowManager.RawWindowInfo] {
        ids.enumerated().map { raw($1, $0, bundleId: bundleId) }
    }

    private func window(_ id: String, in m: WindowManager) -> ManagedWindow? {
        m.windows.first { $0.id == id }
    }

    private func index(_ id: String, in m: WindowManager) -> Int? {
        m.windows.firstIndex { $0.id == id }
    }

    private let ids = ["A", "B", "C", "D", "E"]

    /// Five windows in a manual order, as the owner had them.
    private func placedManager() -> WindowManager {
        let m = manager()
        m.applyWindowSnapshot(snapshot(ids))
        m.setOrder(ids)
        return m
    }

    // MARK: - Grace period

    /// The reproduction from the live evidence, as the PRD lists it.
    func testAWindowMissingFromOneSnapshotKeepsColorIndexAndEnabledFlag() {
        let m = placedManager()
        m.toggleWindow("E", enabled: true)
        let colorE = window("E", in: m)?.assignedColor
        XCTAssertEqual(index("E", in: m), 4)

        clock.advance(2)
        m.applyWindowSnapshot(snapshot(Array(ids.prefix(4))))
        XCTAssertEqual(m.windows.count, 4, "windows holds live windows only")
        XCTAssertNil(window("E", in: m))
        XCTAssertTrue(m.customOrder.contains("E"), "a held window keeps its id in customOrder")
        XCTAssertNotNil(m.autoColors["E"], "one missing snapshot never forgets a color")

        clock.advance(2)
        m.applyWindowSnapshot(snapshot(ids))
        XCTAssertEqual(index("E", in: m), 4)
        XCTAssertEqual(window("E", in: m)?.assignedColor, colorE)
        XCTAssertEqual(window("E", in: m)?.isEnabled, true)
    }

    /// At the end of the list a returning window and a brand-new one land on
    /// the same index; in the middle only a kept slot puts it back.
    func testAWindowMissingFromTheMiddleComesBackToItsSlot() {
        let m = placedManager()
        clock.advance(2)
        m.applyWindowSnapshot(snapshot(["A", "C", "D", "E"]))
        clock.advance(2)
        m.applyWindowSnapshot(snapshot(ids))
        XCTAssertEqual(m.windows.map(\.id), ids)
        XCTAssertEqual(m.customOrder, ids)
    }

    func testAnITermWindowKeepsItsSessionAndEnabledFlagThroughTheDrop() {
        let iterm = TerminalApp.iterm2.bundleIdentifier
        let m = manager()
        m.applyWindowSnapshot(snapshot(ids, bundleId: iterm))
        m.setOrder(ids)
        guard let e = index("E", in: m) else { return XCTFail("E missing") }
        m.windows[e].iterm2SessionId = "SESSION-E"
        m.windows[e].iterm2Tty = "ttys009"
        m.windows[e].subtitle = "vibecut"
        m.toggleWindow("E", enabled: true)

        clock.advance(2)
        m.applyWindowSnapshot(snapshot(Array(ids.prefix(4)), bundleId: iterm))
        clock.advance(2)
        m.applyWindowSnapshot(snapshot(ids, bundleId: iterm))

        let back = window("E", in: m)
        XCTAssertEqual(back?.iterm2SessionId, "SESSION-E")
        XCTAssertEqual(back?.iterm2Tty, "ttys009")
        XCTAssertEqual(back?.subtitle, "vibecut")
        XCTAssertEqual(back?.isEnabled, true)
        XCTAssertEqual(index("E", in: m), 4)
    }

    func testAfterTheGraceTheWindowIsForgottenAndAReturnIsNew() {
        let m = placedManager()
        m.toggleWindow("C", enabled: true)
        let colorC = window("C", in: m)?.assignedColor

        clock.advance(2)
        m.applyWindowSnapshot(snapshot(["A", "B", "D", "E"]))
        XCTAssertNotNil(m.vanished["C"])
        clock.advance(WindowManager.vanishGrace + 1)
        m.applyWindowSnapshot(snapshot(["A", "B", "D", "E"]))
        XCTAssertNil(m.vanished["C"], "held past its grace")
        XCTAssertFalse(m.customOrder.contains("C"), "forgotten for real: its slot is gone")

        clock.advance(2)
        m.applyWindowSnapshot(snapshot(["A", "B", "C", "D", "E"]))
        let back = window("C", in: m)
        XCTAssertEqual(back?.isEnabled, false, "a window back after the grace is a new window")
        XCTAssertEqual(index("C", in: m), 4, "a new window joins the end of a manual order")
        XCTAssertEqual(back?.assignedColor, colorC,
                       "its remembered automatic color still applies: that memory lasts 24 h")
    }

    /// A manual order that differs from screen order, and an enabled window:
    /// without the grace both were lost, while screen order dealt the same
    /// order and first-free colors again, so order and colors alone could not
    /// tell.
    func testAnEmptySnapshotInTheMiddleChangesNothing() {
        let m = manager()
        m.applyWindowSnapshot(snapshot(ids))
        m.setOrder(ids.reversed())
        m.toggleWindow("C", enabled: true)
        let before = m.windows.map { ($0.id, $0.assignedColor) }
        XCTAssertEqual(before.map(\.0), Array(ids.reversed()), "precondition: not the screen order")
        clock.advance(2)
        m.applyWindowSnapshot([])
        XCTAssertTrue(m.windows.isEmpty)
        clock.advance(2)
        m.applyWindowSnapshot(snapshot(ids))
        let after = m.windows.map { ($0.id, $0.assignedColor) }
        XCTAssertTrue(m.usesManualOrder, "the user's order is still the user's")
        XCTAssertEqual(after.map(\.0), before.map(\.0), "same order")
        XCTAssertEqual(m.customOrder, Array(ids.reversed()))
        XCTAssertEqual(after.map(\.1), before.map(\.1), "same colors")
        XCTAssertEqual(window("C", in: m)?.isEnabled, true, "still enabled")
    }

    func testANewWindowDoesNotTakeAHeldWindowsColor() {
        let m = manager()
        m.applyWindowSnapshot(snapshot(["A", "B"]))
        let colorB = window("B", in: m)?.assignedColor
        clock.advance(2)
        m.applyWindowSnapshot(snapshot(["A", "N"]))
        XCTAssertNotEqual(window("N", in: m)?.assignedColor, colorB,
                          "B is expected back; its color is not free")
    }

    // MARK: - Remembered automatic colors

    func testARecreatedManagerGivesEveryWindowTheSameColor() {
        let first = manager()
        first.applyWindowSnapshot(snapshot(ids))
        let colors = Dictionary(uniqueKeysWithValues: first.windows.map { ($0.id, $0.assignedColor) })

        // A Mac restart: a new manager on the same defaults, and a snapshot in a
        // different order, which a fresh assignment would color differently.
        let second = manager()
        second.applyWindowSnapshot(snapshot(ids.reversed()))
        for id in ids {
            XCTAssertEqual(window(id, in: second)?.assignedColor, colors[id], "window \(id)")
        }
    }

    /// The owner's list holds dozens of windows over ten colors, so many share
    /// one. A restart must not re-color a window just because a window earlier
    /// in the new snapshot remembered the same color.
    func testARestartWithMoreWindowsThanColorsKeepsEveryColor() {
        let fifteen = (0..<15).map { "w\($0)" }
        let first = manager()
        first.applyWindowSnapshot(snapshot(fifteen))
        let colors = Dictionary(uniqueKeysWithValues: first.windows.map { ($0.id, $0.assignedColor) })
        XCTAssertEqual(colors["w11"], colors["w1"], "precondition: two windows share a color")
        XCTAssertNotEqual(colors["w1"], WindowColor.palette[0],
                          "precondition: a re-colored w1 would get the first palette color, so this can tell")

        let second = manager()
        // w11 first: it remembers w1's color, which used to push w1 to a fresh one.
        second.applyWindowSnapshot(snapshot(["w11"] + fifteen.filter { $0 != "w11" }))
        for id in fifteen {
            XCTAssertEqual(window(id, in: second)?.assignedColor, colors[id], "window \(id)")
        }
    }

    func testPickThenResetGivesBackThePreviousAutomaticColor() {
        let m = manager()
        m.applyWindowSnapshot(snapshot(["A", "B", "C"]))
        let automatic = window("B", in: m)?.assignedColor
        m.setColor("B", hex: "#123456")
        XCTAssertEqual(window("B", in: m)?.assignedColor, "#123456")
        // A takes a picked color too, so the first free palette color is A's old
        // one, not B's: only the remembered color can give B its own back.
        m.setColor("A", hex: "#654321")
        let others = Set(m.windows.filter { $0.id != "B" }.map(\.assignedColor))
        XCTAssertNotEqual(WindowManager.firstUnusedPaletteColor(avoiding: others), automatic,
                          "precondition: a fresh pick would not be B's old color")
        m.setColor("B", hex: nil)
        XCTAssertEqual(window("B", in: m)?.assignedColor, automatic)
    }

    func testMoreThan200IdsDropsTheLeastRecentlySeen() {
        let m = manager()
        for i in 0...WindowManager.autoColorMaxCount {
            m.applyWindowSnapshot([raw("w\(i)", 0)])
            clock.advance(1)
        }
        XCTAssertEqual(m.autoColors.count, WindowManager.autoColorMaxCount)
        XCTAssertNil(m.autoColors["w0"], "the least recently seen id goes first")
        XCTAssertNotNil(m.autoColors["w\(WindowManager.autoColorMaxCount)"])
    }

    func testPrune_dropsIdsUnseenFor24Hours_andCapsTheCount() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let colors = ["old": "#F5A623", "recent": "#4A90D9"]
        let seen = ["old": now.addingTimeInterval(-25 * 3600), "recent": now.addingTimeInterval(-23 * 3600)]
        let pruned = WindowManager.prunedAutoColors(colors, lastSeen: seen, now: now)
        XCTAssertEqual(Set(pruned.colors.keys), ["recent"])
        XCTAssertEqual(Set(pruned.lastSeen.keys), ["recent"])

        let many = Dictionary(uniqueKeysWithValues: (0..<5).map { ("id\($0)", "#F5A623") })
        let manySeen = Dictionary(uniqueKeysWithValues: (0..<5).map { ("id\($0)", now.addingTimeInterval(Double($0))) })
        let capped = WindowManager.prunedAutoColors(many, lastSeen: manySeen, now: now.addingTimeInterval(10),
                                                    maxCount: 3)
        XCTAssertEqual(Set(capped.colors.keys), ["id2", "id3", "id4"])
    }

    // MARK: - Pure helpers

    func testReinserting_putsHeldIdsBackAtTheirOldIndex() {
        XCTAssertEqual(WindowManager.reinserting(["B", "D"], from: ["A", "B", "C", "D", "E"],
                                                 into: ["A", "C", "E"]),
                       ["A", "B", "C", "D", "E"])
        XCTAssertEqual(WindowManager.reinserting(["E"], from: ["A", "E"], into: ["A"]), ["A", "E"])
        XCTAssertEqual(WindowManager.reinserting(["X"], from: ["A"], into: ["A"]), ["A"],
                       "an id the previous order never listed is not added")
        XCTAssertEqual(WindowManager.reinserting([], from: ["A", "B"], into: ["A"]), ["A"])
    }

    func testWindowReturnedLogLine_namesIdsAndCountsNeverTitles() {
        XCTAssertEqual(WindowManager.windowReturnedLogLine([(id: "com.googlecode.iterm2.4346", absentSnapshots: 1)],
                                                           suppressed: 0),
                       "window_returned id=com.googlecode.iterm2.4346 absent_snapshots=1")
        let many = (0..<7).map { (id: "w\($0)", absentSnapshots: $0 == 3 ? 2 : 1) }
        XCTAssertEqual(WindowManager.windowReturnedLogLine(many, suppressed: 4),
                       "window_returned count=7 absent_snapshots=2 ids=w0,w1,w2,w3,w4,+2 suppressed=4")
    }
}
