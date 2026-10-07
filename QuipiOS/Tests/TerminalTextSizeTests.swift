import XCTest
@testable import Quip

final class TerminalTextSizeTests: XCTestCase {
    func test_stepsByOnePointWithinBounds() {
        XCTAssertEqual(TerminalTextSize.stepped(10, by: 1), 11)
        XCTAssertEqual(TerminalTextSize.stepped(10, by: -1), 9)
        XCTAssertEqual(TerminalTextSize.stepped(TerminalTextSize.maximum, by: 1), TerminalTextSize.maximum)
        XCTAssertEqual(TerminalTextSize.stepped(TerminalTextSize.minimum, by: -1), TerminalTextSize.minimum)
    }

    func test_stepFromAPinchedHalfPointLandsOnWholePoints() {
        XCTAssertEqual(TerminalTextSize.stepped(12.5, by: 1), 14)
    }

    func test_pinchScalesAndRoundsToHalfPoints() {
        XCTAssertEqual(TerminalTextSize.pinched(10, scale: 1.5), 15)
        XCTAssertEqual(TerminalTextSize.pinched(10, scale: 1.13), 11.5)
        XCTAssertEqual(TerminalTextSize.pinched(10, scale: 10), TerminalTextSize.maximum)
        XCTAssertEqual(TerminalTextSize.pinched(10, scale: 0.1), TerminalTextSize.minimum)
    }

    func test_screenshotZoomNeverShrinksBelowFit() {
        XCTAssertEqual(ScreenshotZoom.clamped(0.5), 1)
        XCTAssertEqual(ScreenshotZoom.clamped(2), 2)
        XCTAssertEqual(ScreenshotZoom.clamped(9), ScreenshotZoom.maximum)
    }
}
