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
}
