import XCTest
@testable import Quip

final class LandingPolicyTests: XCTestCase {
    private typealias Input = LandingPolicy.Input

    private func decide(_ input: Input) -> LandingPolicy.Decision { LandingPolicy.decide(input) }

    // MARK: decide (Q-88 §5, steps 1, 2, 5, 6)

    func test_explicitBeatsFollowAndRecency() {
        let d = decide(Input(explicit: "A", followFrontmost: true, macFrontmost: "B",
                             recency: ["C"], windows: ["A", "B", "C"]))
        XCTAssertEqual(d, .init(windowId: "A", reason: .explicit))
    }

    func test_explicitNotInTheLayout_fallsThrough() {
        XCTAssertEqual(decide(Input(explicit: "Z", recency: ["B"], windows: ["A", "B"])),
                       .init(windowId: "B", reason: .recent))
    }

    func test_followOn_landsOnTheMacFrontmost() {
        XCTAssertEqual(decide(Input(followFrontmost: true, macFrontmost: "B", recency: ["A"], windows: ["A", "B"])),
                       .init(windowId: "B", reason: .follow))
    }

    func test_followOff_ignoresTheMacFrontmost() {
        XCTAssertEqual(decide(Input(followFrontmost: false, macFrontmost: "B", recency: ["A"], windows: ["A", "B"])),
                       .init(windowId: "A", reason: .recent))
    }

    func test_followOn_frontmostUntracked_fallsToRecency() {
        XCTAssertEqual(decide(Input(followFrontmost: true, macFrontmost: nil, recency: ["A"], windows: ["A", "B"])),
                       .init(windowId: "A", reason: .recent))
        XCTAssertEqual(decide(Input(followFrontmost: true, macFrontmost: "Z", recency: ["A"], windows: ["A", "B"])),
                       .init(windowId: "A", reason: .recent))
    }

    func test_stackCBA_layoutAB_landsOnB() {
        XCTAssertEqual(decide(Input(recency: ["C", "B", "A"], windows: ["A", "B"])),
                       .init(windowId: "B", reason: .recent))
    }

    func test_savedWindowGone_recencyExcludingIt() {
        XCTAssertEqual(decide(Input(recency: ["B", "A"], windows: ["A", "B"], excluding: "B")),
                       .init(windowId: "A", reason: .recent))
    }

    func test_excludedWindow_isNeverChosenEvenWhenFollowedOrExplicit() {
        XCTAssertEqual(decide(Input(followFrontmost: true, macFrontmost: "B", recency: ["A"],
                                    windows: ["A", "B"], excluding: "B")),
                       .init(windowId: "A", reason: .recent))
        XCTAssertEqual(decide(Input(explicit: "B", recency: ["A"], windows: ["A", "B"], excluding: "B")),
                       .init(windowId: "A", reason: .recent))
    }

    func test_nothingRecentOpen_landsOnFirst() {
        XCTAssertEqual(decide(Input(recency: ["Z"], windows: ["A", "B"])), .init(windowId: "A", reason: .first))
        XCTAssertEqual(decide(Input(windows: ["A", "B"], excluding: "A")), .init(windowId: "B", reason: .first))
    }

    func test_emptyLayout_landsNowhere() {
        XCTAssertEqual(decide(Input(followFrontmost: true, macFrontmost: "A", recency: ["A"], windows: [])),
                       .init(windowId: nil, reason: .none))
    }

    // MARK: afterLayout — the one select_window per layout_update

    func test_selectedWindowVanished_sendsExactlyOneSelectForTheRecencyPick() {
        let out = LandingPolicy.afterLayout(selected: "C", wasEmpty: false,
                                            Input(recency: ["C", "B", "A"], windows: ["A", "B"]))
        XCTAssertEqual(out, .init(selected: "B", send: "B", reason: .recent))
    }

    func test_nothingSelected_landsAndSendsOnce() {
        // A fresh connect: the grid was empty and nothing is selected. The old
        // code sent select_window twice here (initial pick + the wasEmpty resend).
        let out = LandingPolicy.afterLayout(selected: nil, wasEmpty: true,
                                            Input(recency: ["B"], windows: ["A", "B"]))
        XCTAssertEqual(out, .init(selected: "B", send: "B", reason: .recent))
    }

    func test_selectionStillOpen_staysAndSendsNothing() {
        let out = LandingPolicy.afterLayout(selected: "A", wasEmpty: false,
                                            Input(followFrontmost: true, macFrontmost: "B", recency: ["B"],
                                                  windows: ["A", "B"]))
        XCTAssertEqual(out, .init(selected: "A", send: nil, reason: nil))
    }

    func test_selectionStillOpenAfterAnEmptyGrid_resendsItOnce() {
        let out = LandingPolicy.afterLayout(selected: "A", wasEmpty: true, Input(windows: ["A", "B"]))
        XCTAssertEqual(out, .init(selected: "A", send: "A", reason: nil))
    }

    func test_selectedWindowVanishedIntoAnEmptyLayout_clearsAndSendsNothing() {
        let out = LandingPolicy.afterLayout(selected: "A", wasEmpty: false, Input(recency: ["A"], windows: []))
        XCTAssertEqual(out, .init(selected: nil, send: nil, reason: LandingPolicy.Reason.none))
    }
}
