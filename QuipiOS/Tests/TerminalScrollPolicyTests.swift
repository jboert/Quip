import XCTest
@testable import Quip

final class TerminalScrollPolicyTests: XCTestCase {
    func test_atTheBottomFollowsNewOutput() {
        XCTAssertTrue(TerminalScrollPolicy.isPinnedToBottom(contentHeight: 1000, offsetY: 600, visibleHeight: 400))
    }

    func test_nearTheBottomStillFollows() {
        XCTAssertTrue(TerminalScrollPolicy.isPinnedToBottom(contentHeight: 1000, offsetY: 570, visibleHeight: 400))
    }

    func test_scrolledUpStaysPut() {
        XCTAssertFalse(TerminalScrollPolicy.isPinnedToBottom(contentHeight: 1000, offsetY: 200, visibleHeight: 400))
    }

    func test_contentShorterThanTheViewFollows() {
        // A fresh view has no content yet; it must start at the bottom.
        XCTAssertTrue(TerminalScrollPolicy.isPinnedToBottom(contentHeight: 0, offsetY: 0, visibleHeight: 400))
    }
}
