import XCTest
@testable import Quip

/// Q-90 US-002: the plain-words banner and its change-only log rule.
final class MacDownBannerTests: XCTestCase {
    typealias Content = MacDownBanner.Content
    typealias ContentFn = (MacDown, TimeInterval, Bool) -> Content?

    private func assertDelay(_ content: ContentFn, file: StaticString = #filePath, line: UInt = #line) {
        for kind in [MacDown.quipDown, .offline, .unknown] {
            for hostSet in [true, false] {
                XCTAssertNil(content(kind, 14, hostSet), "\(kind) at 14 s", file: file, line: line)
                XCTAssertNil(content(kind, 0, hostSet), "\(kind) at 0 s", file: file, line: line)
                XCTAssertNotNil(content(kind, 15, hostSet), "\(kind) at 15 s", file: file, line: line)
            }
        }
    }

    private func content(_ kind: MacDown, _ downFor: TimeInterval, _ hostSet: Bool) -> Content? {
        MacDownBanner.content(kind: kind, downFor: downFor, remoteInHostSet: hostSet)
    }

    func test_hiddenUnder15SecondsShownFrom15() {
        assertDelay(content)
    }

    /// Broken fixture: a content function that ignores downFor must fail the
    /// 15 s assertions, or the suite fails (strict expected failure).
    func test_delayAssertionsCatchAContentThatIgnoresDownFor() {
        let ignoresDownFor: ContentFn = { kind, _, hostSet in
            MacDownBanner.content(kind: kind, downFor: 3600, remoteInHostSet: hostSet)
        }
        XCTExpectFailure("a banner that ignores downFor must fail the 15 s assertions", strict: true)
        assertDelay(ignoresDownFor)
    }

    func test_quipDown_withHost_offersRemoteIn() {
        XCTAssertEqual(content(.quipDown, 15, true),
                       Content(title: "Quip isn't running on your Mac", action: .remoteIn))
    }

    func test_quipDown_withoutHost_offersSetUp() {
        XCTAssertEqual(content(.quipDown, 15, false),
                       Content(title: "Quip isn't running on your Mac", action: .setUpRemoteIn))
    }

    func test_offline_offersCheckTailscale_eitherHostSetting() {
        let want = Content(title: "Can't reach your Mac", action: .checkTailscale)
        XCTAssertEqual(content(.offline, 15, true), want)
        XCTAssertEqual(content(.offline, 15, false), want)
    }

    func test_unknown_hasNoAction_eitherHostSetting() {
        let want = Content(title: "Can't reach your Mac", action: nil)
        XCTAssertEqual(content(.unknown, 15, true), want)
        XCTAssertEqual(content(.unknown, 120, false), want)
    }

    func test_actionTitles() {
        XCTAssertEqual(MacDownBanner.Action.remoteIn.title, "Remote in")
        XCTAssertEqual(MacDownBanner.Action.setUpRemoteIn.title, "Set up Remote in")
        XCTAssertEqual(MacDownBanner.Action.checkTailscale.title, "Check Tailscale")
    }

    // MARK: US-004 "Restarting…" while the Mac is protected

    typealias GraceFn = (TimeInterval, Bool) -> Content?
    static let restarting = "Quip on your Mac stopped. Restarting… usually under a minute"

    private func status(watching: Bool) -> ReliabilityStatusMessage {
        ReliabilityStatusMessage(watching: watching, afterQuit: true, watchdog: true)
    }

    private func watching(_ downFor: TimeInterval, _ hostSet: Bool) -> Content? {
        MacDownBanner.content(kind: .quipDown, downFor: downFor, remoteInHostSet: hostSet,
                              reliability: status(watching: true))
    }

    private func assertGrace(_ content: GraceFn, file: StaticString = #filePath, line: UInt = #line) {
        for (hostSet, action) in [(true, MacDownBanner.Action.remoteIn), (false, .setUpRemoteIn)] {
            XCTAssertNil(content(14, hostSet), "hidden under 15 s", file: file, line: line)
            XCTAssertEqual(content(15, hostSet), Content(title: Self.restarting, action: nil), file: file, line: line)
            XCTAssertEqual(content(89, hostSet), Content(title: Self.restarting, action: nil), file: file, line: line)
            XCTAssertEqual(content(90, hostSet), Content(title: Self.restarting, action: action), file: file, line: line)
            XCTAssertEqual(content(600, hostSet), Content(title: Self.restarting, action: action), file: file, line: line)
        }
    }

    func test_watching_saysRestarting_remoteInOnlyFrom90Seconds() {
        assertGrace(watching)
    }

    /// Broken fixture: a banner that offers Remote in at once must fail the
    /// 89 s assertion, or the suite fails (strict expected failure).
    func test_graceAssertionsCatchABannerThatSkipsTheWait() {
        let noGrace: GraceFn = { downFor, hostSet in
            downFor < 15 ? nil : self.watching(600, hostSet)
        }
        XCTExpectFailure("a banner that offers Remote in before 90 s must fail", strict: true)
        assertGrace(noGrace)
    }

    func test_notWatchingOrUnknown_behavesAsUS002() {
        for reliability in [status(watching: false), nil] {
            for (downFor, hostSet) in [(14.0, true), (15, true), (15, false), (89, true), (300, false)] {
                XCTAssertEqual(
                    MacDownBanner.content(kind: .quipDown, downFor: downFor, remoteInHostSet: hostSet, reliability: reliability),
                    content(.quipDown, downFor, hostSet), "watching=\(String(describing: reliability?.watching)) at \(downFor) s")
            }
        }
        XCTAssertEqual(MacDownBanner.content(kind: .quipDown, downFor: 15, remoteInHostSet: true, reliability: status(watching: false)),
                       Content(title: "Quip isn't running on your Mac", action: .remoteIn))
    }

    func test_watching_doesNotChangeOfflineOrUnknown() {
        for kind in [MacDown.offline, .unknown] {
            XCTAssertEqual(MacDownBanner.content(kind: kind, downFor: 15, remoteInHostSet: true, reliability: status(watching: true)),
                           content(kind, 15, true))
        }
    }

    // MARK: change-only log rule

    func test_logLine_onlyWhenKindChanges() {
        // A run of probes: unknown, unknown, quip_down, quip_down, offline.
        var logged: MacDown?
        var lines: [String] = []
        for (kind, ms) in [(MacDown.unknown, 0), (.unknown, 0), (.quipDown, 12), (.quipDown, 9), (.offline, 3000)] {
            if let line = MacDownBanner.logLine(previous: logged, next: kind, probeMs: ms) { lines.append(line) }
            logged = kind
        }
        XCTAssertEqual(lines, [
            "mac_down kind=unknown probe_ms=0",
            "mac_down kind=quip_down probe_ms=12",
            "mac_down kind=offline probe_ms=3000",
        ])
    }

    func test_logLine_firstProbeAlwaysLogs() {
        XCTAssertEqual(MacDownBanner.logLine(previous: nil, next: .quipDown, probeMs: 5),
                       "mac_down kind=quip_down probe_ms=5")
        XCTAssertNil(MacDownBanner.logLine(previous: .quipDown, next: .quipDown, probeMs: 5))
    }

    // MARK: Stop Quip… on the Mac

    func test_stopped_saysStopped_offersRemoteInAtOnce() {
        let stopped = ReliabilityStatusMessage(watching: false, afterQuit: true, watchdog: true, stopped: true)
        XCTAssertNil(MacDownBanner.content(kind: .quipDown, downFor: 14, remoteInHostSet: true, reliability: stopped))
        XCTAssertEqual(MacDownBanner.content(kind: .quipDown, downFor: 15, remoteInHostSet: true, reliability: stopped),
                       Content(title: "Quip was stopped on your Mac", action: .remoteIn))
        XCTAssertEqual(MacDownBanner.content(kind: .quipDown, downFor: 15, remoteInHostSet: false, reliability: stopped),
                       Content(title: "Quip was stopped on your Mac", action: .setUpRemoteIn))
        // Even a status that also says watching: stopped wins, nothing restarts it.
        let both = ReliabilityStatusMessage(watching: true, afterQuit: true, watchdog: true, stopped: true)
        XCTAssertEqual(MacDownBanner.content(kind: .quipDown, downFor: 20, remoteInHostSet: true, reliability: both)?.title,
                       "Quip was stopped on your Mac")
        // An offline Mac is still offline.
        XCTAssertEqual(MacDownBanner.content(kind: .offline, downFor: 20, remoteInHostSet: true, reliability: stopped)?.action,
                       .checkTailscale)
    }
}
