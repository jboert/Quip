import XCTest
@testable import Quip

/// Q-88 US-003: the Mac's frontmost window feeds the per-Mac recency stack,
/// with at most one persisted write per backend per second.
@MainActor
final class RecencyWriteCoalescerTests: XCTestCase {

    /// Stored stacks, the writes made, and the flushes waiting on the clock.
    @MainActor private final class Rig {
        var stored: [String: [String]] = [:]
        var writes: [(backendId: String, recent: [String])] = []
        var timers: [(delay: TimeInterval, fire: () -> Void)] = []
        lazy var coalescer = RecencyWriteCoalescer(
            load: { [unowned self] in self.stored[$0] ?? [] },
            persist: { [unowned self] recent, backendId in
                self.stored[backendId] = recent
                self.writes.append((backendId, recent))
            },
            schedule: { [unowned self] delay, fire in self.timers.append((delay, fire)) })

        /// Advances the clock past every scheduled flush.
        func tick() {
            let due = timers
            timers.removeAll()
            due.forEach { $0.fire() }
        }
    }

    func test_twoEventsWithinTheInterval_makeOneWriteInTheLatestOrder() {
        let rig = Rig()
        rig.stored["mac"] = ["A"]

        rig.coalescer.touch("B", forBackendId: "mac")
        rig.coalescer.touch("C", forBackendId: "mac")   // 100 ms later: no timer has fired yet

        XCTAssertTrue(rig.writes.isEmpty, "nothing is written before the interval ends")
        XCTAssertEqual(rig.timers.count, 1, "one flush per backend per interval")
        XCTAssertEqual(rig.timers.first?.delay, RecencyWriteCoalescer.interval)
        rig.tick()
        XCTAssertEqual(rig.writes.map(\.recent), [["C", "B", "A"]])
    }

    func test_thePendingOrderIsReadBeforeItIsWritten() {
        let rig = Rig()
        rig.stored["mac"] = ["A"]
        rig.coalescer.touch("B", forBackendId: "mac")
        XCTAssertEqual(rig.coalescer.recent(forBackendId: "mac"), ["B", "A"])
    }

    func test_theWindowAlreadyOnTop_writesNothing() {
        // The Mac echoes the phone's own select_window as frontmost_changed.
        let rig = Rig()
        rig.stored["mac"] = ["A", "B"]
        rig.coalescer.touch("A", forBackendId: "mac")
        XCTAssertTrue(rig.timers.isEmpty)
        rig.tick()
        XCTAssertTrue(rig.writes.isEmpty)
    }

    func test_aLaterBurst_isItsOwnWrite() {
        let rig = Rig()
        rig.coalescer.touch("A", forBackendId: "mac")
        rig.tick()
        rig.coalescer.touch("B", forBackendId: "mac")
        rig.tick()
        XCTAssertEqual(rig.writes.map(\.recent), [["A"], ["B", "A"]])
    }

    func test_backendsCoalesceSeparately() {
        let rig = Rig()
        rig.coalescer.touch("A", forBackendId: "one")
        rig.coalescer.touch("X", forBackendId: "two")
        XCTAssertEqual(rig.timers.count, 2)
        rig.tick()
        XCTAssertEqual(rig.stored, ["one": ["A"], "two": ["X"]])
    }

    func test_rememberWritesAtOnceOnTopOfThePendingOrder() {
        // A phone tap is the user's own choice: written now, and it must not be
        // overwritten by the older frontmost order when the timer fires.
        let rig = Rig()
        rig.stored["mac"] = ["A"]
        rig.coalescer.touch("B", forBackendId: "mac")
        rig.coalescer.remember("C", forBackendId: "mac")
        XCTAssertEqual(rig.writes.map(\.recent), [["C", "B", "A"]])
        rig.tick()
        XCTAssertEqual(rig.writes.count, 1, "the flush has nothing left to write")
        XCTAssertEqual(rig.stored["mac"], ["C", "B", "A"])
    }

    func test_flushAll_writesWhatIsPendingBeforeTheAppGoesAway() {
        let rig = Rig()
        rig.coalescer.touch("A", forBackendId: "one")
        rig.coalescer.touch("X", forBackendId: "two")
        rig.coalescer.flushAll()
        XCTAssertEqual(rig.stored, ["one": ["A"], "two": ["X"]])
        rig.tick()
        XCTAssertEqual(rig.writes.count, 2, "the timers find nothing left")
    }

    func test_theDefaultStoreIsWindowSelectionMemory() throws {
        let suite = "RecencyWriteCoalescerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        WindowSelectionMemory.remember("A", forBackendId: "mac", defaults: defaults)
        let coalescer = RecencyWriteCoalescer(defaults: defaults, schedule: { _, fire in fire() })

        coalescer.touch("B", forBackendId: "mac")

        XCTAssertEqual(WindowSelectionMemory.recent(forBackendId: "mac", defaults: defaults), ["B", "A"])
    }
}

/// Q-88 US-003: `frontmost_changed` reaches the stack through the manager for
/// every paired Mac, active or not, and only for windows that Mac tracks.
@MainActor
final class FrontmostRecencyWiringTests: XCTestCase {

    private var ids: [String] = []
    private var savedDefaults: [String: Any] = [:]
    private let keys = ["pairedBackendsData", "activeBackendID"]

    override func setUp() {
        super.setUp()
        for key in keys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in keys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        ids.forEach { KeychainBackendPINs.delete(backendID: $0) }
        super.tearDown()
    }

    private func rig() -> (BackendConnectionManager, () -> [String: [String]]) {
        var stored: [String: [String]] = [:]
        let manager = BackendConnectionManager()
        manager.recency = RecencyWriteCoalescer(load: { stored[$0] ?? [] },
                                                persist: { stored[$1] = $0 },
                                                schedule: { _, fire in fire() })
        for n in 1...2 {
            let id = "q88-us003-\(n)-\(UUID().uuidString)"
            ids.append(id)
            // Distinct URLs: `add` folds a URL another row already has into that row.
            manager.add(PairedBackend(id: id, url: "ws://127.0.0.1:\(8 + n)", name: "Mac \(n)"), pin: "0000")
        }
        return (manager, { stored })
    }

    private func frontmost(_ windowId: String?, on session: BackendSession) throws {
        session.client.isAuthenticated = true
        session.client.handleMessage(try JSONEncoder().encode(FrontmostChangedMessage(windowId: windowId)))
    }

    private func window(_ id: String) -> WindowState {
        WindowState(id: id, name: id, app: "iTerm2", enabled: true,
                    frame: WindowFrame(x: 0, y: 0, width: 1, height: 1), state: "neutral", color: "#000000")
    }

    func test_aTrackedFrontmostReordersThatMacsStack_evenWithFollowOff() throws {
        let (manager, stored) = rig()
        let session = try XCTUnwrap(manager.sessions[ids[0]])
        session.windows = [window("A"), window("B")]
        var forwarded: [String?] = []
        manager.onFrontmostChanged = { _, id in forwarded.append(id) }

        try frontmost("B", on: session)

        XCTAssertEqual(stored()[ids[0]], ["B"])
        XCTAssertEqual(forwarded, ["B"], "the UI handler still decides selection (follow on or off)")
    }

    func test_anUntrackedOrNilFrontmostChangesNothing() throws {
        let (manager, stored) = rig()
        let session = try XCTUnwrap(manager.sessions[ids[0]])
        session.windows = [window("A")]

        try frontmost("Z", on: session)
        try frontmost(nil, on: session)

        XCTAssertNil(stored()[ids[0]])
    }

    func test_anInactiveMacsEventUpdatesOnlyThatMacsStack() throws {
        let (manager, stored) = rig()
        XCTAssertEqual(manager.activeBackendID, ids[0])
        let inactive = try XCTUnwrap(manager.sessions[ids[1]])
        inactive.windows = [window("W4")]

        try frontmost("W4", on: inactive)

        XCTAssertEqual(stored()[ids[1]], ["W4"])
        XCTAssertNil(stored()[ids[0]])
    }
}
