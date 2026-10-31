import XCTest
@testable import Quip

final class ReliabilityTests: XCTestCase {

    // MARK: LaunchOwnership

    private func assertOwnership(
        _ decide: (Bool, Bool) -> LaunchOwnership,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(decide(false, false), .run, "no agent: nobody to hand off to", file: file, line: line)
        XCTAssertEqual(decide(false, true), .run, "no agent (stale env): run", file: file, line: line)
        XCTAssertEqual(decide(true, false), .handOff, "agent installed, launched by hand: hand off", file: file, line: line)
        XCTAssertEqual(decide(true, true), .run, "launched by the agent: this is the watched copy", file: file, line: line)
    }

    func test_launchOwnership_everyCase() {
        assertOwnership { LaunchOwnership.decide(agentInstalled: $0, launchedByAgent: $1) }
    }

    func test_launchOwnership_brokenFixtureFails() {
        // Hands off whenever the launch did not come from the agent, even with
        // no agent installed: Quip would exit and never come back.
        let broken: (Bool, Bool) -> LaunchOwnership = { _, launchedByAgent in
            launchedByAgent ? .run : .handOff
        }
        XCTExpectFailure("a decide that hands off when not installed must fail", strict: true)
        assertOwnership(broken)
    }

    // MARK: ReliabilitySettings

    func test_settings_everyCombination() {
        for keepRunning in [false, true] {
            for afterQuit in [false, true] {
                for frozen in [false, true] {
                    let a = ReliabilitySettings.agents(keepRunning: keepRunning, afterQuit: afterQuit, frozen: frozen)
                    let label = "keepRunning=\(keepRunning) afterQuit=\(afterQuit) frozen=\(frozen)"
                    XCTAssertEqual(a.crashAgent, keepRunning, label)
                    XCTAssertEqual(a.keepAliveAlways, keepRunning && afterQuit, label)
                    XCTAssertEqual(a.watchdog, keepRunning && frozen, label)
                }
            }
        }
    }

    func test_settings_keepRunningOff_installsNothing() {
        let a = ReliabilitySettings.agents(keepRunning: false, afterQuit: true, frozen: true)
        XCTAssertFalse(a.crashAgent)
        XCTAssertFalse(a.keepAliveAlways)
        XCTAssertFalse(a.watchdog)
    }

    func test_settings_allOn() {
        let a = ReliabilitySettings.agents(keepRunning: true, afterQuit: true, frozen: true)
        XCTAssertTrue(a.crashAgent)
        XCTAssertTrue(a.keepAliveAlways)
        XCTAssertTrue(a.watchdog)
    }

    func test_settings_keepRunningOnly_crashAgentAlone() {
        let a = ReliabilitySettings.agents(keepRunning: true, afterQuit: false, frozen: false)
        XCTAssertTrue(a.crashAgent)
        XCTAssertFalse(a.keepAliveAlways)
        XCTAssertFalse(a.watchdog)
    }

    // MARK: ReliabilityStatus

    private func status(loaded: Bool, agentPid: Int?, quipPid: Int = 4242) -> ReliabilityStatusMessage {
        ReliabilityStatus.build(
            agentLoaded: loaded, agentPid: agentPid, quipPid: quipPid,
            afterQuit: true, watchdog: false, lastRestart: nil
        )
    }

    func test_status_watching_whenLoadedAndPidMatches() {
        XCTAssertTrue(status(loaded: true, agentPid: 4242).watching)
    }

    func test_status_notWatching_whenPidMismatch() {
        XCTAssertFalse(status(loaded: true, agentPid: 999).watching)
    }

    func test_status_notWatching_whenAgentPidNil() {
        XCTAssertFalse(status(loaded: true, agentPid: nil).watching)
    }

    func test_status_notWatching_whenNotLoaded() {
        XCTAssertFalse(status(loaded: false, agentPid: 4242).watching)
    }

    func test_status_passesFlagsAndLastRestartThrough() {
        let last = ReliabilityStatusMessage.LastRestart(reason: "hang", at: 1_800_000_000)
        let m = ReliabilityStatus.build(
            agentLoaded: true, agentPid: 7, quipPid: 7,
            afterQuit: false, watchdog: true, lastRestart: last
        )
        XCTAssertEqual(m, ReliabilityStatusMessage(watching: true, afterQuit: false, watchdog: true, lastRestart: last))
        XCTAssertEqual(m.type, "reliability_status")

        let m2 = ReliabilityStatus.build(
            agentLoaded: true, agentPid: 7, quipPid: 7,
            afterQuit: true, watchdog: false, lastRestart: nil
        )
        XCTAssertTrue(m2.afterQuit)
        XCTAssertFalse(m2.watchdog)
        XCTAssertNil(m2.lastRestart)
    }

    // MARK: CrashRecoveryAgent KeepAlive shapes

    func test_crashAgent_keepAliveAlways_isBooleanTrue() throws {
        let dict = CrashRecoveryAgent.plistContent(executablePath: "/x", keepAliveAlways: true)
        XCTAssertEqual(dict["KeepAlive"] as? Bool, true)
        XCTAssertNil(dict["KeepAlive"] as? [String: Any], "must be the boolean, not a dict")

        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let xml = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(xml.contains("<key>KeepAlive</key>\n\t<true/>"), xml)
    }

    func test_crashAgent_keepAliveFalse_isCrashOnlyDict() {
        let dict = CrashRecoveryAgent.plistContent(executablePath: "/x", keepAliveAlways: false)
        let ka = dict["KeepAlive"] as? [String: Any]
        XCTAssertEqual(ka?["Crashed"] as? Bool, true)
        XCTAssertEqual(ka?["SuccessfulExit"] as? Bool, false)
        XCTAssertEqual(ka?.count, 2)
    }

    func test_crashAgent_defaultIsTodaysCrashOnlyDict() {
        let dict = CrashRecoveryAgent.plistContent(executablePath: "/x")
        let ka = dict["KeepAlive"] as? [String: Any]
        XCTAssertEqual(ka?["Crashed"] as? Bool, true)
        XCTAssertEqual(ka?["SuccessfulExit"] as? Bool, false)
    }

    func test_crashAgent_otherKeysUnchangedByKeepAliveAlways() {
        let dict = CrashRecoveryAgent.plistContent(executablePath: "/x", keepAliveAlways: true)
        XCTAssertEqual(dict["Label"] as? String, "com.quip.QuipMac.crash-recovery")
        XCTAssertEqual(dict["ProgramArguments"] as? [String], ["/x"])
        XCTAssertEqual(dict["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(dict["ThrottleInterval"] as? Int, 30)
    }

    // MARK: WatchdogAgent

    func test_watchdogPlist_keys() throws {
        let script = "/Applications/Quip.app/Contents/Resources/quip-watchdog.sh"
        let dict = WatchdogAgent.plistContent(scriptPath: script)
        XCTAssertEqual(dict["Label"] as? String, "com.quip.QuipMac.watchdog")
        XCTAssertEqual(WatchdogAgent.label, "com.quip.QuipMac.watchdog")
        XCTAssertEqual(dict["ProgramArguments"] as? [String], ["/bin/sh", script])
        XCTAssertEqual(dict["StartInterval"] as? Int, 30)
        XCTAssertEqual(dict["RunAtLoad"] as? Bool, true)
        XCTAssertNil(dict["KeepAlive"], "the watchdog runs on an interval, not kept alive")

        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        XCTAssertEqual(parsed?["StartInterval"] as? Int, 30)
        XCTAssertEqual(parsed?["ProgramArguments"] as? [String], ["/bin/sh", script])
    }

    // MARK: ReliabilityAgents.desired

    private func plist(_ data: Data?) throws -> [String: Any]? {
        guard let data else { return nil }
        return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }

    func test_desired_followsTheSettings() throws {
        let all = ReliabilityAgents.desired(agents: (true, true, true), executablePath: "/x", scriptPath: "/s.sh")
        XCTAssertEqual(try plist(all.crash)?["KeepAlive"] as? Bool, true)
        XCTAssertEqual(try plist(all.watchdog)?["ProgramArguments"] as? [String], ["/bin/sh", "/s.sh"])

        let crashOnly = ReliabilityAgents.desired(agents: (true, false, false), executablePath: "/x", scriptPath: "/s.sh")
        XCTAssertEqual((try plist(crashOnly.crash)?["KeepAlive"] as? [String: Any])?["Crashed"] as? Bool, true)
        XCTAssertNil(crashOnly.watchdog)

        let off = ReliabilityAgents.desired(agents: (false, false, false), executablePath: "/x", scriptPath: "/s.sh")
        XCTAssertNil(off.crash)
        XCTAssertNil(off.watchdog)
    }

    func test_desired_noScriptInTheBundle_noWatchdog() {
        XCTAssertNil(ReliabilityAgents.desired(agents: (true, true, true), executablePath: "/x", scriptPath: nil).watchdog)
    }

    func test_desired_isStable_soAnUnchangedSettingNeverReloads() {
        let a = ReliabilityAgents.desired(agents: (true, true, true), executablePath: "/x", scriptPath: "/s.sh")
        let b = ReliabilityAgents.desired(agents: (true, true, true), executablePath: "/x", scriptPath: "/s.sh")
        XCTAssertEqual(a.crash, b.crash)
        XCTAssertEqual(a.watchdog, b.watchdog)
    }

    func test_prefs_defaultOn() {
        let d = UserDefaults(suiteName: "ReliabilityTests.prefs")!
        d.removePersistentDomain(forName: "ReliabilityTests.prefs")
        defer { d.removePersistentDomain(forName: "ReliabilityTests.prefs") }
        let a = ReliabilityPrefs.agents(in: d)
        XCTAssertTrue(a.crashAgent && a.keepAliveAlways && a.watchdog, "an install that never saw the switches is protected")
        d.set(false, forKey: ReliabilityPrefs.keepRunningKey)
        XCTAssertFalse(ReliabilityPrefs.agents(in: d).crashAgent)
    }

    // MARK: ReliabilityReport

    func test_agentPid_fromLaunchctlPrint() {
        let running = "gui/501/com.quip.QuipMac.crash-recovery = {\n\tstate = running\n\tpid = 4242\n\truns = 2\n}"
        XCTAssertEqual(ReliabilityReport.agentPid(launchctlPrint: running), 4242)
        let stopped = "gui/501/com.quip.QuipMac.crash-recovery = {\n\tstate = not running\n\truns = 1\n\tlast exit code = 0\n}"
        XCTAssertNil(ReliabilityReport.agentPid(launchctlPrint: stopped))
    }

    func test_lastRestart_onlyTheOneThatStartedThisQuip() {
        let json = Data(#"[{"at": 1000, "reason": "crash"}, {"at": 3000, "reason": "hang"}, {"at": 2000, "reason": "quit"}]"#.utf8)
        XCTAssertEqual(ReliabilityReport.lastRestart(restartsJSON: json, since: Date(timeIntervalSince1970: 2500)),
                       .init(reason: "hang", at: 3000))
        XCTAssertNil(ReliabilityReport.lastRestart(restartsJSON: json, since: Date(timeIntervalSince1970: 3001)),
                     "a phone that pairs later hears nothing old")
        XCTAssertNil(ReliabilityReport.lastRestart(restartsJSON: nil, since: .distantPast))
        XCTAssertNil(ReliabilityReport.lastRestart(restartsJSON: Data("junk".utf8), since: .distantPast))
    }

    // MARK: ReliabilityRestarts

    func test_recent_newestFirst_limitFive_marksASameCauseThreeTimes() {
        let json = Data(#"""
        [{"at": 100, "reason": "hang"}, {"at": 200, "reason": "crash"}, {"at": 300, "reason": "hang"},
         {"at": 400, "reason": "quit"}, {"at": 500, "reason": "hang"}, {"at": 600, "reason": "crash"},
         {"at": 50, "reason": "hang"}]
        """#.utf8)
        let r = ReliabilityRestarts.recent(restartsJSON: json)
        XCTAssertEqual(r.map(\.reason), ["crash", "hang", "quit", "hang", "crash"])
        XCTAssertEqual(r.first?.at, Date(timeIntervalSince1970: 600))
        XCTAssertEqual(r.map(\.repeated), [false, false, false, false, false], "only two hangs among the last five")

        let three = Data(#"[{"at": 1, "reason": "hang"}, {"at": 2, "reason": "hang"}, {"at": 3, "reason": "hang"}, {"at": 4, "reason": "crash"}]"#.utf8)
        XCTAssertEqual(ReliabilityRestarts.recent(restartsJSON: three).map(\.repeated), [false, true, true, true])
        XCTAssertEqual(ReliabilityRestarts.recent(restartsJSON: nil), [])
    }

    func test_ticketText_hasNoHomePath() {
        let e = ReliabilityRestarts.Entry(at: Date(timeIntervalSince1970: 1_793_415_963), reason: "hang", repeated: true)
        let t = ReliabilityRestarts.ticketText(e, build: "1.5.7 (1708) f9ee248", sample: "hang-20261031T030603Z.txt")
        XCTAssertEqual(t, """
        Quip restart: hang
        at: 2026-10-31T03:06:03Z
        build: 1.5.7 (1708) f9ee248
        same cause 3+ times in the last restarts
        hang sample: ~/Library/Logs/Quip/hang-20261031T030603Z.txt
        """)
        XCTAssertFalse(t.contains(NSHomeDirectory()))
    }

    func test_sampleName_matchesTheHangWithinAMinute() {
        let e = ReliabilityRestarts.Entry(at: Date(timeIntervalSince1970: 1_793_415_963), reason: "hang", repeated: false)
        let names = ["hang-20261031T030603Z.txt", "hang-20261030T010000Z.txt", "watchdog.log"]
        XCTAssertEqual(ReliabilityRestarts.sampleName(for: e, in: names), "hang-20261031T030603Z.txt")
        let crash = ReliabilityRestarts.Entry(at: e.at, reason: "crash", repeated: false)
        XCTAssertNil(ReliabilityRestarts.sampleName(for: crash, in: names))
        let later = ReliabilityRestarts.Entry(at: e.at.addingTimeInterval(3600), reason: "hang", repeated: false)
        XCTAssertNil(ReliabilityRestarts.sampleName(for: later, in: names))
    }

    func test_turnOn_isRefusedFromATunnel() {
        XCTAssertEqual(WebSocketServer.refusedTunnelType(in: Data(#"{"type":"reliability_turn_on"}"#.utf8)),
                       "reliability_turn_on")
    }
}
