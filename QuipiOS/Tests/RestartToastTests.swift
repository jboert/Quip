import XCTest
@testable import Quip

/// Q-90 US-004: the once-per-restart toast and its wording.
final class RestartToastTests: XCTestCase {
    typealias Restart = ReliabilityStatusMessage.LastRestart
    typealias IsNewFn = (Double?, Restart?) -> Bool

    /// 2026-10-30 14:04:00 UTC: 2:04 pm in UTC.
    static let at: Double = 1_793_369_040
    static let utc = TimeZone(identifier: "UTC")!

    private func assertIsNew(_ isNew: IsNewFn, file: StaticString = #filePath, line: UInt = #line) {
        let restart = Restart(reason: "crash", at: Self.at)
        XCTAssertTrue(isNew(nil, restart), "never shown one: new", file: file, line: line)
        XCTAssertTrue(isNew(Self.at - 1, restart), "newer than the last shown: new", file: file, line: line)
        XCTAssertFalse(isNew(Self.at, restart), "the one already shown: not new", file: file, line: line)
        XCTAssertFalse(isNew(Self.at + 1, restart), "older than the last shown: not new", file: file, line: line)
        XCTAssertFalse(isNew(nil, nil), "no restart reported", file: file, line: line)
        XCTAssertFalse(isNew(Self.at, nil), "no restart reported", file: file, line: line)
    }

    func test_isNew() {
        assertIsNew(RestartToast.isNew)
    }

    /// Broken fixture: a rule that toasts every status that carries a
    /// restart must fail, or the suite fails (strict expected failure).
    func test_isNewAssertionsCatchARuleThatRepeatsTheToast() {
        let everyTime: IsNewFn = { _, incoming in incoming != nil }
        XCTExpectFailure("a rule that ignores lastShown must fail the not-new cases", strict: true)
        assertIsNew(everyTime)
    }

    func test_text_eachReason() {
        func text(_ reason: String) -> String { RestartToast.text(reason: reason, at: Self.at, timeZone: Self.utc) }
        XCTAssertEqual(text("crash"), "Quip on your Mac restarted after a crash (2:04 pm)")
        XCTAssertEqual(text("hang"), "Quip on your Mac restarted after it froze (2:04 pm)")
        XCTAssertEqual(text("crash_loop"), "Quip on your Mac restarted after crashing repeatedly (2:04 pm)")
        XCTAssertEqual(text("quit"), "Quip on your Mac restarted after it was quit (2:04 pm)")
        XCTAssertEqual(text("something_new"), "Quip on your Mac restarted (2:04 pm)")
    }

    func test_text_morningTime() {
        XCTAssertEqual(RestartToast.text(reason: "crash", at: Self.at - 5 * 3600 - 4 * 60, timeZone: Self.utc),
                       "Quip on your Mac restarted after a crash (9:00 am)")
    }

    func test_logLine() {
        XCTAssertEqual(RestartToast.logLine(reason: "crash_loop"), "mac_restarted reason=crash_loop")
    }

    func test_lastShown_keptPerBackend() {
        let defaults = UserDefaults(suiteName: "RestartToastTests")!
        defaults.removePersistentDomain(forName: "RestartToastTests")
        defer { defaults.removePersistentDomain(forName: "RestartToastTests") }
        XCTAssertNil(RestartToast.lastShown(backendID: "a", defaults: defaults))
        RestartToast.markShown(Self.at, backendID: "a", defaults: defaults)
        XCTAssertEqual(RestartToast.lastShown(backendID: "a", defaults: defaults), Self.at)
        XCTAssertNil(RestartToast.lastShown(backendID: "b", defaults: defaults))
    }
}
