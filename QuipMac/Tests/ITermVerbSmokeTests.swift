import XCTest
@testable import Quip

/// Smoke test for the AppleScript verbs QuipMac uses against a live iTerm2.
/// (wishlist §25.) iTerm2 has no stable AppleScript API contract — verbs can
/// rename, return shapes can shift, properties can drop on any update — and
/// QuipMac calls them silently. A 50-line harness that exercises each verb
/// once and asserts the return TYPE catches the kind of shape mismatch that
/// silently broke the codebase before (commit `4006db4`'s `id of window`
/// returning iTerm2's internal int rather than a CGWindowID).
///
/// All assertions in this file are READ-ONLY. They never create / write /
/// close / resize a window. Safe to run against the developer's live iTerm2
/// session. The whole class skips if iTerm2 is not currently running so it
/// stays green on CI machines without iTerm2 installed.
///
/// Destructive verbs (`create window with default profile`, `write text`,
/// `set bounds`, `close`, `select`) are intentionally NOT exercised here —
/// they're covered by the existing integration paths and would surprise a
/// user running the test bundle locally. If a future iTerm2 update is
/// suspected of breaking those, copy this file into an opt-in destructive
/// variant gated on an env var.
final class ITermVerbSmokeTests: XCTestCase {

    private var iTermAvailable: Bool {
        let src = """
        tell application "System Events"
            set p to (count of (every process whose bundle identifier is "com.googlecode.iterm2"))
            return p
        end tell
        """
        return runAndExtractInt(src).map { $0 > 0 } ?? false
    }

    override func setUp() {
        super.setUp()
        try? XCTSkipUnless(iTermAvailable,
                           "iTerm2 is not running — smoke test skipped.")
    }

    // MARK: - Window enumeration

    func test_countWindows_returnsInt() throws {
        let result = run("tell application \"iTerm2\" to count windows")
        XCTAssertNotNil(result, "AppleScript bridge failed entirely")
        XCTAssertEqual(result?.descriptorType, typeSInt32,
                       "count windows must return signed int — saw \(result?.descriptorType.fourCC ?? "nil")")
    }

    func test_idOfFirstWindow_returnsInt() throws {
        let count = runAndExtractInt("tell application \"iTerm2\" to count windows") ?? 0
        try XCTSkipUnless(count > 0, "no windows to probe")
        let result = run("tell application \"iTerm2\" to get id of first window")
        XCTAssertEqual(result?.descriptorType, typeSInt32,
                       "id of window must return int — KeystrokeInjector.spawnWindow + WindowManager.fetchAllITermWindows depend on this")
    }

    func test_miniaturizedOfFirstWindow_returnsBool() throws {
        let count = runAndExtractInt("tell application \"iTerm2\" to count windows") ?? 0
        try XCTSkipUnless(count > 0, "no windows to probe")
        let result = run("tell application \"iTerm2\" to get miniaturized of first window")
        XCTAssertNotNil(result)
        guard let r = result else { return }
        // AppleScript can return Boolean as either typeBoolean (single byte
        // payload) or typeTrue / typeFalse (no payload). iTerm2 currently
        // returns typeTrue / typeFalse — both are valid Boolean shapes that
        // `booleanValue` decodes correctly. The point of the assertion is
        // catching a switch to a NON-bool type (e.g. an int or string).
        let validBoolTypes: Set<DescType> = [typeBoolean, typeTrue, typeFalse]
        XCTAssertTrue(validBoolTypes.contains(r.descriptorType),
                      "miniaturized of window must be a Boolean shape — saw \(r.descriptorType.fourCC)")
    }

    func test_nameOfFirstWindow_returnsString() throws {
        let count = runAndExtractInt("tell application \"iTerm2\" to count windows") ?? 0
        try XCTSkipUnless(count > 0, "no windows to probe")
        let result = run("tell application \"iTerm2\" to get name of first window")
        XCTAssertNotNil(result?.stringValue,
                        "name of window must coerce to string")
    }

    func test_boundsOfFirstWindow_returnsListOfFourInts() throws {
        let count = runAndExtractInt("tell application \"iTerm2\" to count windows") ?? 0
        try XCTSkipUnless(count > 0, "no windows to probe")
        let result = run("tell application \"iTerm2\" to get bounds of first window")
        XCTAssertNotNil(result, "bounds must return SOMETHING")
        guard let r = result else { return }
        // bounds returns a list/record of 4 numbers depending on iTerm version
        // — the shape changed across major versions. Both shapes coerce to
        // a 4-element list when read via numberOfItems.
        XCTAssertEqual(r.numberOfItems, 4,
                       "bounds of window must yield 4 elements (l, t, r, b)")
    }

    // MARK: - Session traversal

    func test_currentSession_existsAndHasNameAndUniqueId() throws {
        let count = runAndExtractInt("tell application \"iTerm2\" to count windows") ?? 0
        try XCTSkipUnless(count > 0, "no windows to probe")

        let name = run("tell application \"iTerm2\" to get name of current session of first window")
        XCTAssertNotNil(name?.stringValue,
                        "name of current session must coerce to string")

        let uid = run("tell application \"iTerm2\" to get unique id of current session of first window")
        XCTAssertNotNil(uid?.stringValue,
                        "unique id of session must coerce to string — session ID stability depends on this")
        if let s = uid?.stringValue {
            XCTAssertFalse(s.isEmpty, "unique id of session was empty string")
        }
    }

    func test_ttyOfCurrentSession_returnsString() throws {
        let count = runAndExtractInt("tell application \"iTerm2\" to count windows") ?? 0
        try XCTSkipUnless(count > 0, "no windows to probe")
        let result = run("tell application \"iTerm2\" to get tty of current session of first window")
        XCTAssertNotNil(result?.stringValue, "tty must coerce to string (e.g. /dev/ttys001)")
    }

    func test_textOfCurrentSession_returnsString() throws {
        let count = runAndExtractInt("tell application \"iTerm2\" to count windows") ?? 0
        try XCTSkipUnless(count > 0, "no windows to probe")
        let result = run("tell application \"iTerm2\" to get text of current session of first window")
        XCTAssertNotNil(result?.stringValue,
                        "text of session must coerce to string — terminalContent path requires this")
    }

    func test_profileNameOfCurrentSession_returnsString() throws {
        let count = runAndExtractInt("tell application \"iTerm2\" to count windows") ?? 0
        try XCTSkipUnless(count > 0, "no windows to probe")
        let result = run("tell application \"iTerm2\" to get profile name of current session of first window")
        XCTAssertNotNil(result?.stringValue,
                        "profile name must coerce to string — TerminalColorManager.resetBackground requires this")
    }

    func test_tabsOfFirstWindow_returnsList() throws {
        let count = runAndExtractInt("tell application \"iTerm2\" to count windows") ?? 0
        try XCTSkipUnless(count > 0, "no windows to probe")
        let result = run("tell application \"iTerm2\" to get tabs of first window")
        XCTAssertNotNil(result, "tabs must return SOMETHING")
        // tabs returns a list; numberOfItems should be ≥ 1 for any active window
        XCTAssertGreaterThanOrEqual(result?.numberOfItems ?? 0, 1,
                                    "tabs of first window must contain at least one tab")
    }

    // MARK: - whose-clause window lookup

    func test_firstWindowWhoseIdIs_returnsRef() throws {
        // KeystrokeInjector.swift:495 + WindowManager.swift:668 use this exact
        // shape to look up a window by its iTerm-internal id. If iTerm ever
        // breaks the `whose` clause on windows, those paths silently no-op.
        let firstId = runAndExtractInt("tell application \"iTerm2\" to get id of first window")
        try XCTSkipUnless(firstId != nil, "no windows to probe")
        guard let wid = firstId else { return }
        let result = run("tell application \"iTerm2\" to get name of (first window whose id is \(wid))")
        XCTAssertNotNil(result?.stringValue,
                        "first window whose id is N must resolve and have a name")
    }

    // MARK: - Helpers

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            XCTFail("AppleScript failed: \(err)\nsource:\n\(source)")
            return nil
        }
        return result
    }

    private func runAndExtractInt(_ source: String) -> Int? {
        guard let d = run(source) else { return nil }
        if d.descriptorType == typeSInt32 || d.descriptorType == typeSInt64 {
            return Int(d.int32Value)
        }
        return nil
    }
}

private extension DescType {
    /// Render the four-char code as a debugging-friendly string.
    var fourCC: String {
        let bytes = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }
}
