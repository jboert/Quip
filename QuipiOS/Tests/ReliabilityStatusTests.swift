import XCTest
@testable import Quip

/// Q-90 US-003: `reliability_status` on the wire, its per-backend store and
/// the Settings "Auto-restart" summary.
final class ReliabilityStatusTests: XCTestCase {
    typealias Summary = (ReliabilityStatusMessage?) -> (text: String, warn: Bool)

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ReliabilityStatusTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private let watching = ReliabilityStatusMessage(watching: true, afterQuit: true, watchdog: true)
    private let installedNotWatching = ReliabilityStatusMessage(watching: false, afterQuit: true, watchdog: true)
    private let off = ReliabilityStatusMessage(watching: false, afterQuit: false, watchdog: false)

    // MARK: Wire

    func test_roundTrip_withLastRestart() throws {
        let status = ReliabilityStatusMessage(watching: true, afterQuit: false, watchdog: true,
                                              lastRestart: .init(reason: "hang", at: 1_793_000_000.5))
        let decoded = try JSONDecoder().decode(ReliabilityStatusMessage.self,
                                               from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
        XCTAssertEqual(decoded.type, "reliability_status")
        XCTAssertEqual(decoded.lastRestart?.reason, "hang")
        XCTAssertEqual(decoded.lastRestart?.at, 1_793_000_000.5)
    }

    func test_roundTrip_withoutLastRestart() throws {
        let decoded = try JSONDecoder().decode(ReliabilityStatusMessage.self,
                                               from: JSONEncoder().encode(off))
        XCTAssertEqual(decoded, off)
        XCTAssertNil(decoded.lastRestart)
    }

    /// What a Mac (or tools/fake-mac) puts on the wire, with lastRestart absent.
    func test_decode_toleratesMissingLastRestart() throws {
        let json = #"{"type":"reliability_status","watching":false,"afterQuit":true,"watchdog":false}"#
        let decoded = try JSONDecoder().decode(ReliabilityStatusMessage.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.watching)
        XCTAssertTrue(decoded.afterQuit)
        XCTAssertFalse(decoded.watchdog)
        XCTAssertNil(decoded.lastRestart)
    }

    func test_decode_readsLastRestartFromWire() throws {
        let json = #"{"type":"reliability_status","watching":true,"afterQuit":true,"watchdog":true,"lastRestart":{"reason":"crash_loop","at":1793000000}}"#
        let decoded = try JSONDecoder().decode(ReliabilityStatusMessage.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.lastRestart, .init(reason: "crash_loop", at: 1_793_000_000))
    }

    // MARK: Store

    func test_store_keyIsVersionedPerBackend() {
        XCTAssertEqual(ReliabilityStatusStore.key(backendID: "abc"), "reliability.v1.abc")
    }

    func test_store_saveLoad_keepsBackendsSeparate() {
        XCTAssertNil(ReliabilityStatusStore.load(backendID: "mac-a", defaults: defaults))
        let restarted = ReliabilityStatusMessage(watching: true, afterQuit: true, watchdog: false,
                                                 lastRestart: .init(reason: "crash", at: 42))
        ReliabilityStatusStore.save(restarted, backendID: "mac-a", defaults: defaults)
        ReliabilityStatusStore.save(off, backendID: "mac-b", defaults: defaults)
        XCTAssertEqual(ReliabilityStatusStore.load(backendID: "mac-a", defaults: defaults), restarted)
        XCTAssertEqual(ReliabilityStatusStore.load(backendID: "mac-b", defaults: defaults), off)
        XCTAssertNil(ReliabilityStatusStore.load(backendID: "mac-c", defaults: defaults))
        XCTAssertNotNil(defaults.data(forKey: "reliability.v1.mac-a"), "stored as JSON data under the v1 key")
    }

    func test_store_saveOverwritesTheLatest() {
        ReliabilityStatusStore.save(watching, backendID: "mac-a", defaults: defaults)
        ReliabilityStatusStore.save(off, backendID: "mac-a", defaults: defaults)
        XCTAssertEqual(ReliabilityStatusStore.load(backendID: "mac-a", defaults: defaults), off)
    }

    func test_store_garbageLoadsAsNil() {
        defaults.set(Data("not json".utf8), forKey: ReliabilityStatusStore.key(backendID: "mac-a"))
        XCTAssertNil(ReliabilityStatusStore.load(backendID: "mac-a", defaults: defaults))
    }

    // MARK: Summary

    private func assertSummaryRows(_ summary: Summary, file: StaticString = #filePath, line: UInt = #line) {
        let unknown = summary(nil)
        XCTAssertEqual(unknown.text, "Unknown", file: file, line: line)
        XCTAssertFalse(unknown.warn, "nil is not a warning", file: file, line: line)
        let on = summary(watching)
        XCTAssertEqual(on.text, "On", file: file, line: line)
        XCTAssertFalse(on.warn, "watching is not a warning", file: file, line: line)
        for status in [installedNotWatching, off] {
            let row = summary(status)
            XCTAssertEqual(row.text, "Off — turn on in Quip on your Mac", file: file, line: line)
            XCTAssertTrue(row.warn, "not watching must warn", file: file, line: line)
        }
    }

    func test_summary_everyRow() {
        assertSummaryRows(ReliabilityStatusStore.summary)
    }

    /// Broken fixture: a summary that calls not-watching "On" must fail the
    /// warn assertions, or the suite fails (strict expected failure).
    func test_summaryAssertionsCatchNotWatchingShownAsOn() {
        let broken: Summary = { status in
            status == nil ? ("Unknown", false) : ("On", false)
        }
        XCTExpectFailure("a summary that maps not-watching to On must fail the warn assertions", strict: true)
        assertSummaryRows(broken)
    }
}
