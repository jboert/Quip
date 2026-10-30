import XCTest
@testable import Quip

/// Q-88 US-009: jump to a window that is asking something, after time away.
final class SmartLandingTests: XCTestCase {
    private typealias C = SmartLanding.Candidate

    private let menu = "Do you want to proceed?\n❯ 1. Yes\n  2. No"
    private let idleAgent = "⏺ Done.\n╭──────╮\n│ >    │\n╰──────╯"

    // MARK: shouldTry

    func test_away3Minutes_tries_away1Minute_doesNot() {
        XCTAssertTrue(SmartLanding.shouldTry(away: 180, enabled: true, followFrontmost: false, explicit: false, threshold: 120))
        XCTAssertFalse(SmartLanding.shouldTry(away: 60, enabled: true, followFrontmost: false, explicit: false, threshold: 120))
        XCTAssertTrue(SmartLanding.shouldTry(away: 120, enabled: true, followFrontmost: false, explicit: false, threshold: 120))
    }

    func test_settingOff_followOn_explicit_neverAway_doNotTry() {
        XCTAssertFalse(SmartLanding.shouldTry(away: 999, enabled: false, followFrontmost: false, explicit: false, threshold: 120))
        XCTAssertFalse(SmartLanding.shouldTry(away: 999, enabled: true, followFrontmost: true, explicit: false, threshold: 120))
        XCTAssertFalse(SmartLanding.shouldTry(away: 999, enabled: true, followFrontmost: false, explicit: true, threshold: 120))
        XCTAssertFalse(SmartLanding.shouldTry(away: nil, enabled: true, followFrontmost: false, explicit: false, threshold: 120))
    }

    // MARK: pick

    func test_otherWindowAsking_jumps() {
        let windows = [C(id: "A", isWaiting: false, isAgent: true, content: "working"),
                       C(id: "B", isWaiting: true, isAgent: true, content: menu)]
        XCTAssertEqual(SmartLanding.pick(current: "A", windows: windows, recency: ["A"]), "B")
    }

    func test_idleAgent_waitingButNotAsking_staysPut() {
        let windows = [C(id: "A", isWaiting: false, isAgent: true, content: "working"),
                       C(id: "B", isWaiting: true, isAgent: true, content: idleAgent)]
        XCTAssertNil(SmartLanding.pick(current: "A", windows: windows, recency: []))
    }

    func test_currentWindowItselfAsking_stays() {
        let windows = [C(id: "A", isWaiting: true, isAgent: true, content: menu),
                       C(id: "B", isWaiting: true, isAgent: true, content: menu)]
        XCTAssertNil(SmartLanding.pick(current: "A", windows: windows, recency: ["B"]))
    }

    func test_twoAsking_higherInRecencyWins_thenMacOrder() {
        let windows = [C(id: "A", isWaiting: true, isAgent: true, content: menu),
                       C(id: "B", isWaiting: true, isAgent: true, content: menu),
                       C(id: "C", isWaiting: false, isAgent: true, content: nil)]
        XCTAssertEqual(SmartLanding.pick(current: "C", windows: windows, recency: ["B", "A"]), "B")
        XCTAssertEqual(SmartLanding.pick(current: "C", windows: windows, recency: []), "A")
    }

    func test_askingButNotWaiting_doesNotCount() {
        let windows = [C(id: "B", isWaiting: false, isAgent: true, content: menu)]
        XCTAssertNil(SmartLanding.pick(current: "A", windows: windows, recency: []))
    }

    func test_noScreen_doesNotCount() {
        XCTAssertNil(SmartLanding.pick(current: "A", windows: [C(id: "B", isWaiting: true, isAgent: false, content: nil)],
                                       recency: []))
    }

    // MARK: asksSomething

    func test_questions() {
        XCTAssertTrue(SmartLanding.asksSomething(menu, isAgent: true))
        XCTAssertTrue(SmartLanding.asksSomething("Start a cloud session?\n❯ Yes\n  No", isAgent: true))
        XCTAssertTrue(SmartLanding.asksSomething("Overwrite? (y/n)", isAgent: true))
        XCTAssertTrue(SmartLanding.asksSomething("output\nRemove file.txt?", isAgent: false))
    }

    func test_notQuestions() {
        XCTAssertFalse(SmartLanding.asksSomething(idleAgent, isAgent: true))
        XCTAssertFalse(SmartLanding.asksSomething("Want me to run the tests?", isAgent: true), "agent prose")
        XCTAssertFalse(SmartLanding.asksSomething("build ok\n$ ", isAgent: false))
    }

    // MARK: probes

    func test_probes_waitingOthers_mostRecentFirst_capped() {
        let windows = (1...6).map { C(id: "W\($0)", isWaiting: true, isAgent: true, content: nil) }
            + [C(id: "X", isWaiting: false, isAgent: true, content: nil)]
        XCTAssertEqual(SmartLanding.probes(current: "W1", windows: windows, recency: ["W5"]),
                       ["W5", "W2", "W3", "W4"])
    }
}
