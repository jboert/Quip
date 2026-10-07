import XCTest
@testable import Quip

final class TerminalAppReadScriptTests: XCTestCase {
    func test_visibleScreenReadIsUnchanged() {
        let script = KeystrokeInjector.terminalAppReadScript(windowNumber: 72, fullHistory: false)
        XCTAssertTrue(script.contains("return contents of window id 72"))
        XCTAssertTrue(script.contains("return contents of front window"))
        XCTAssertFalse(script.contains("history"))
    }

    func test_fullHistoryReadsTheSelectedTabsScrollback() {
        let script = KeystrokeInjector.terminalAppReadScript(windowNumber: 72, fullHistory: true)
        XCTAssertTrue(script.contains("return history of selected tab of window id 72"))
        XCTAssertTrue(script.contains("return history of selected tab of front window"))
    }

    func test_noWindowNumberFallsBackToTheFrontWindow() {
        let script = KeystrokeInjector.terminalAppReadScript(windowNumber: 0, fullHistory: true)
        XCTAssertTrue(script.contains("return history of selected tab of front window"))
        XCTAssertFalse(script.contains("window id"))
    }
}
