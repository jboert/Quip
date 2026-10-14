import XCTest
@testable import Quip

/// The terminal panel asks the Mac for the selected window every 2 s. The Mac
/// answers every request except one for a window id it no longer has, so a
/// closed window, a sleeping Mac or a dead socket all look the same on the
/// phone: "Loading…" forever, or the last text frozen with nothing saying so.
final class TerminalPanelFreshnessTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: staleLabel

    func test_noLabelWhileTheTextIsFresh() {
        XCTAssertNil(TerminalPanelFreshness.staleLabel(lastUpdate: t0, now: t0.addingTimeInterval(9.9)))
    }

    func test_noLabelBeforeTheFirstReply() {
        // Nothing to call old yet: the loading branch speaks for this case.
        XCTAssertNil(TerminalPanelFreshness.staleLabel(lastUpdate: nil, now: t0))
    }

    func test_secondsThenMinutesThenHours() {
        XCTAssertEqual(TerminalPanelFreshness.staleLabel(lastUpdate: t0, now: t0.addingTimeInterval(10)), "10 s old")
        XCTAssertEqual(TerminalPanelFreshness.staleLabel(lastUpdate: t0, now: t0.addingTimeInterval(59.9)), "59 s old")
        XCTAssertEqual(TerminalPanelFreshness.staleLabel(lastUpdate: t0, now: t0.addingTimeInterval(60)), "1 min old")
        XCTAssertEqual(TerminalPanelFreshness.staleLabel(lastUpdate: t0, now: t0.addingTimeInterval(3599)), "59 min old")
        XCTAssertEqual(TerminalPanelFreshness.staleLabel(lastUpdate: t0, now: t0.addingTimeInterval(7200)), "2 h old")
    }

    func test_aClockThatWentBackwardsIsNotStale() {
        XCTAssertNil(TerminalPanelFreshness.staleLabel(lastUpdate: t0, now: t0.addingTimeInterval(-30)))
    }

    func test_spokenLabelSaysWhatTheChipMeans() {
        XCTAssertEqual(TerminalPanelFreshness.spokenStaleLabel(lastUpdate: t0, now: t0.addingTimeInterval(75)),
                       "No update from the Mac for 1 minute")
        XCTAssertEqual(TerminalPanelFreshness.spokenStaleLabel(lastUpdate: t0, now: t0.addingTimeInterval(12)),
                       "No update from the Mac for 12 seconds")
        XCTAssertNil(TerminalPanelFreshness.spokenStaleLabel(lastUpdate: t0, now: t0.addingTimeInterval(3)))
    }

    // MARK: loadingText

    func test_loadingKeepsItsOwnWordsAtFirst() {
        XCTAssertEqual(TerminalPanelFreshness.loadingText(base: "Loading…", waitingSince: t0,
                                                          now: t0.addingTimeInterval(7.9)),
                       "Loading…")
    }

    func test_aLongWaitSaysTheMacHasNotAnswered() {
        let text = TerminalPanelFreshness.loadingText(base: "Loading…", waitingSince: t0,
                                                      now: t0.addingTimeInterval(8))
        XCTAssertTrue(text.hasPrefix("No reply from the Mac"), text)
        XCTAssertTrue(text.contains("closed"), "names the likely cause: \(text)")
    }

    func test_unknownStartKeepsTheBaseText() {
        XCTAssertEqual(TerminalPanelFreshness.loadingText(base: "Waiting for screenshot…", waitingSince: nil, now: t0),
                       "Waiting for screenshot…")
    }
}
