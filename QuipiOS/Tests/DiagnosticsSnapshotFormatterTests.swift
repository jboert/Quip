import XCTest
@testable import Quip

/// Locks `DiagnosticsSnapshotFormatter.format(_:now:)` output shape so
/// the bug-report copy/paste workflow stays grep-friendly. Users learn
/// to look for specific lines ("connected: true", "lastError: ...");
/// shuffling those breaks every triage cheat-sheet downstream. (§26.)
final class DiagnosticsSnapshotFormatterTests: XCTestCase {

    private static let frozenNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(events: [String] = [],
                        reason: DisconnectReason? = nil) -> DiagnosticsSnapshotFormatter.Input {
        DiagnosticsSnapshotFormatter.Input(
            appVersion: "1.5.3",
            buildNumber: "9999",
            isConnected: true,
            isConnecting: false,
            isAuthenticated: true,
            lastError: nil,
            lastDisconnectReason: reason,
            serverURL: "ws://192.168.4.34:8765",
            pairedCount: 2,
            activeBackendName: "Quip Mac Studio23",
            connectionEvents: events
        )
    }

    func test_includesAppVersionLine() {
        let out = DiagnosticsSnapshotFormatter.format(sample(), now: Self.frozenNow)
        XCTAssertTrue(out.contains("App: 1.5.3 (9999)"))
    }

    func test_includesAllConnectionFlags() {
        let out = DiagnosticsSnapshotFormatter.format(sample(), now: Self.frozenNow)
        XCTAssertTrue(out.contains("connected: true"))
        XCTAssertTrue(out.contains("connecting: false"))
        XCTAssertTrue(out.contains("authenticated: true"))
    }

    func test_lastErrorNil_rendersAsNoneSentinel() {
        let out = DiagnosticsSnapshotFormatter.format(sample(), now: Self.frozenNow)
        XCTAssertTrue(out.contains("lastError: <none>"),
                      "nil renders as <none> sentinel so triage scripts can grep a stable token")
    }

    func test_lastErrorPresent_rendersVerbatim() {
        var inp = sample()
        inp = .init(appVersion: inp.appVersion, buildNumber: inp.buildNumber,
                    isConnected: false, isConnecting: true, isAuthenticated: false,
                    lastError: "Stalled 26s — resetting",
                    lastDisconnectReason: nil,
                    serverURL: inp.serverURL, pairedCount: inp.pairedCount,
                    activeBackendName: inp.activeBackendName, connectionEvents: inp.connectionEvents)
        let out = DiagnosticsSnapshotFormatter.format(inp, now: Self.frozenNow)
        XCTAssertTrue(out.contains("lastError: Stalled 26s — resetting"))
    }

    func test_disconnectReasonNil_rendersAsNoneSentinel() {
        let out = DiagnosticsSnapshotFormatter.format(sample(reason: nil), now: Self.frozenNow)
        XCTAssertTrue(out.contains("lastDisconnectReason: <none>"))
    }

    func test_disconnectReasonPresent_rendersBareTagToken() {
        // Tag is the bare case name (no associated values) — stays grep-friendly
        // even when the human-readable label changes wording.
        let out = DiagnosticsSnapshotFormatter.format(sample(reason: .stalled(seconds: 26)),
                                                     now: Self.frozenNow)
        XCTAssertTrue(out.contains("lastDisconnectReason: stalled"),
                      "stalled tag should appear without the seconds payload")
    }

    func test_disconnectReasonAuthFailed_rendersAuthFailedTag() {
        let out = DiagnosticsSnapshotFormatter.format(
            sample(reason: .authFailed(message: "Wrong PIN")),
            now: Self.frozenNow
        )
        XCTAssertTrue(out.contains("lastDisconnectReason: authFailed"))
    }

    func test_includesPairedCount_andActiveName() {
        let out = DiagnosticsSnapshotFormatter.format(sample(), now: Self.frozenNow)
        XCTAssertTrue(out.contains("paired: 2"))
        XCTAssertTrue(out.contains("active: Quip Mac Studio23"))
    }

    func test_emptyEvents_rendersNoneSentinel() {
        let out = DiagnosticsSnapshotFormatter.format(sample(events: []), now: Self.frozenNow)
        XCTAssertTrue(out.contains("## Recent connection events (newest last)\n<none>"))
    }

    func test_eventsRendered_inOrderProvided() {
        let events = [
            "[2026-05-06T12:34:56Z] connect(toURLs: 2 total, primary: ws://x)",
            "[2026-05-06T12:34:57Z] connected, awaiting authentication",
            "[2026-05-06T12:34:58Z] auth_result success"
        ]
        let out = DiagnosticsSnapshotFormatter.format(sample(events: events), now: Self.frozenNow)
        for e in events {
            XCTAssertTrue(out.contains(e), "event line missing: \(e)")
        }
    }

    func test_iso8601_timestampInHeader() {
        let out = DiagnosticsSnapshotFormatter.format(sample(), now: Self.frozenNow)
        XCTAssertTrue(out.contains("2023-11-14"),
                      "Header should carry an ISO8601 timestamp from `now` so timezone is unambiguous in bug reports")
    }
}
