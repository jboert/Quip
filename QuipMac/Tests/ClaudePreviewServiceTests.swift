import XCTest
@testable import Quip

final class ClaudePreviewServiceTests: XCTestCase {
    private func window(_ id: String, bundleId: String = "com.googlecode.iterm2", number: CGWindowID = 0,
                        session: String? = nil, tty: String? = nil) -> ManagedWindow {
        var w = ManagedWindow(
            id: id, name: id, app: bundleId, subtitle: "",
            bundleId: bundleId, icon: nil, isEnabled: true,
            assignedColor: "#F5A623", pid: 1, windowNumber: number,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            iterm2SessionId: session, isOnVisibleScreen: true
        )
        w.iterm2Tty = tty
        return w
    }

    private func report(_ paths: [String], tty: String? = nil, iterm: String? = nil) -> ClaudeHookReport {
        ClaudeHookReport(at: 0, sessionId: "s", cwd: "/", paths: paths, tty: tty, itermSessionId: iterm)
    }

    // MARK: Terminal match

    func test_itermSessionIdMatchesExactly() {
        let windows = [window("a", session: "U1", tty: "ttys001"), window("b", session: "U2", tty: "ttys002")]
        XCTAssertEqual(ClaudePreviewService.terminalWindowId(
            for: report(["/x.png"], tty: "/dev/ttys001", iterm: "U2"), windows: windows, terminalTTYs: [:]), "b")
    }

    func test_ttyMatchesITermWhenNoSessionId() {
        let windows = [window("a", tty: "ttys001"), window("b", tty: "ttys002")]
        XCTAssertEqual(ClaudePreviewService.terminalWindowId(
            for: report(["/x.png"], tty: "/dev/ttys002"), windows: windows, terminalTTYs: [:]), "b")
    }

    func test_ttyMatchesTerminalAppBackgroundTab() {
        let windows = [window("t1", bundleId: "com.apple.Terminal", number: 45),
                       window("t2", bundleId: "com.apple.Terminal", number: 46)]
        let ttys = ClaudePreviewService.parseTerminalTTYs("45:/dev/ttys000\n46:/dev/ttys001\n46:/dev/ttys004\n")
        XCTAssertEqual(ClaudePreviewService.terminalWindowId(
            for: report(["/x.png"], tty: "/dev/ttys004"), windows: windows, terminalTTYs: ttys), "t2")
    }

    func test_noMatchIsUnattachedNeverAGuess() {
        let windows = [window("a", session: "U1", tty: "ttys001")]
        XCTAssertNil(ClaudePreviewService.terminalWindowId(
            for: report(["/x.png"], tty: "/dev/ttys009"), windows: windows, terminalTTYs: [:]))
        XCTAssertNil(ClaudePreviewService.terminalWindowId(
            for: report(["/x.png"]), windows: windows, terminalTTYs: [:]))
    }

    // MARK: Merge

    func test_sameFileTwiceIsOneEntryMovedToFront() {
        let t0 = Date(timeIntervalSince1970: 100), t1 = Date(timeIntervalSince1970: 200)
        var list = ClaudePreviewService.merge(report(["/a.png", "/b.png"]), terminalWindowId: "w", into: [], now: t0)
        XCTAssertEqual(list.map(\.name), ["a.png", "b.png"])
        let idA = list[0].id
        list = ClaudePreviewService.merge(report(["/b.png"]), terminalWindowId: nil, into: list, now: t1)
        XCTAssertEqual(list.map(\.name), ["b.png", "a.png"])
        XCTAssertEqual(list[0].openedAt, t1)
        XCTAssertEqual(list[0].terminalWindowId, "w", "an unmatched re-open keeps the known terminal")
        XCTAssertEqual(list[1].id, idA)
    }

    // MARK: Desktop windows

    func test_fileShownInAWindowTakesIt_andItsGroupFollows() {
        let list = ClaudePreviewService.merge(report(["/a.png", "/b.png"]), terminalWindowId: "w", into: [], now: Date())
        let out = ClaudePreviewService.applyDocuments([7: "/b.png"], liveWindows: [7], to: list)
        XCTAssertEqual(out.map(\.desktopWindowNumber), [7, 7])
    }

    func test_closingTheWindowOnTheMacRemovesIt() {
        var list = ClaudePreviewService.merge(report(["/a.png"]), terminalWindowId: "w", into: [], now: Date())
        list = ClaudePreviewService.applyDocuments([7: "/a.png"], liveWindows: [7], to: list)
        XCTAssertEqual(ClaudePreviewService.applyDocuments([:], liveWindows: [], to: list), [])
    }

    func test_neverSeenInPreviewStays() {
        let list = ClaudePreviewService.merge(report(["/a.png"]), terminalWindowId: "w", into: [], now: Date())
        XCTAssertEqual(ClaudePreviewService.applyDocuments([9: "/other.png"], liveWindows: [9], to: list), list)
    }

    func test_otherPreviewWindowsAreNeverListed() {
        let out = ClaudePreviewService.applyDocuments([1: "/mine.png", 2: "/yours.png"], liveWindows: [1, 2], to: [])
        XCTAssertEqual(out, [])
    }

    func test_expiry() {
        let now = Date(timeIntervalSince1970: 100_000)
        var list = ClaudePreviewService.merge(report(["/old.png"]), terminalWindowId: nil, into: [],
                                              now: now.addingTimeInterval(-ClaudePreviewService.maxAge - 1))
        list = ClaudePreviewService.merge(report(["/new.png", "/gone.png"]), terminalWindowId: nil, into: list, now: now)
        let kept = ClaudePreviewService.expire(list, now: now, fileExists: { $0 != "/gone.png" })
        XCTAssertEqual(kept.map(\.name), ["new.png"])
    }

    // MARK: Report

    func test_itermSessionUUIDStripsThePanePrefix() {
        XCTAssertEqual(ClaudeHookReport.itermSessionUUID("w0t1p0:8C1F-AB"), "8C1F-AB")
        XCTAssertNil(ClaudeHookReport.itermSessionUUID(""))
        XCTAssertNil(ClaudeHookReport.itermSessionUUID(nil))
    }

    func test_nearestTTYWalksUpToTheFirstAncestorWithOne() {
        let chain: [pid_t: ProcessTTY.Info] = [
            50: .init(parent: 40, tty: nil), 40: .init(parent: 30, tty: "/dev/ttys004"), 30: .init(parent: 1, tty: "/dev/ttys000"),
        ]
        XCTAssertEqual(ProcessTTY.nearestTTY(from: 50, lookup: { chain[$0] }), "/dev/ttys004")
        XCTAssertNil(ProcessTTY.nearestTTY(from: 50, maxDepth: 1, lookup: { chain[$0] }))
    }
}
