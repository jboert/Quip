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
}
