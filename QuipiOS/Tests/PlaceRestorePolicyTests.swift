import XCTest
@testable import Quip

/// Q-88 US-006 §5: what comes back from a saved place, in order.
final class PlaceRestorePolicyTests: XCTestCase {
    private let saved = Date(timeIntervalSince1970: 1_800_000_000)

    private func place(window: String? = "W2", display: String? = "2", space: String? = "s1",
                       input: Bool = true, expanded: Bool = true) -> PhonePlace {
        PhonePlace(selectedWindowId: window, selectedDisplayID: display, selectedSpaceID: space,
                   textInputOpen: input, terminalExpanded: expanded, savedAt: saved)
    }

    private func steps(_ place: PhonePlace?, minutes: Double, window: String?,
                       displays: [String] = ["1", "2"], spaces: [String] = ["s1"]) -> [PlaceRestorePolicy.Step] {
        PlaceRestorePolicy.steps(place: place, now: saved.addingTimeInterval(minutes * 60), window: window,
                                 displays: displays, spaces: spaces)
    }

    func test_fresh_restoresChipWindowTerminalInput_inThatOrder() {
        XCTAssertEqual(steps(place(), minutes: 1, window: "W2"),
                       [.display("2"), .space("s1"), .window("W2"), .terminalExpanded(true), .textInputOpen(true)])
    }

    func test_stale_restoresTheWindowOnly() {
        XCTAssertEqual(steps(place(), minutes: 31, window: "W1"), [.window("W1")])
    }

    func test_freshness_isInclusiveAt30Minutes() {
        XCTAssertTrue(PlaceRestorePolicy.isFresh(place(), now: saved.addingTimeInterval(30 * 60)))
        XCTAssertFalse(PlaceRestorePolicy.isFresh(place(), now: saved.addingTimeInterval(30 * 60 + 1)))
    }

    func test_savedDisplayGone_leavesTheChip_windowStillRestored() {
        XCTAssertEqual(steps(place(), minutes: 1, window: "W2", displays: ["1"], spaces: []),
                       [.window("W2"), .terminalExpanded(true), .textInputOpen(true)])
    }

    func test_allScreens_isAChoiceToo() {
        XCTAssertEqual(steps(place(display: nil, space: nil), minutes: 1, window: "W2").prefix(2),
                       [.display(nil), .space(nil)])
    }

    func test_panelFlags_droppedWhenTheWindowDiffers() {
        XCTAssertEqual(steps(place(), minutes: 1, window: "W3"), [.display("2"), .space("s1"), .window("W3")])
    }

    func test_closedPanels_comeBackClosed() {
        XCTAssertEqual(steps(place(input: false, expanded: false), minutes: 1, window: "W2").suffix(2),
                       [.terminalExpanded(false), .textInputOpen(false)])
    }

    func test_noPlaceOrNoWindow() {
        XCTAssertEqual(steps(nil, minutes: 0, window: "W1"), [.window("W1")])
        XCTAssertEqual(steps(nil, minutes: 0, window: nil), [])
        XCTAssertEqual(steps(place(), minutes: 1, window: nil), [.display("2"), .space("s1")])
    }
}
