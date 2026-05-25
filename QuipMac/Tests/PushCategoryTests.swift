import XCTest
@testable import Quip

/// Locks `PushNotificationService.waitingCategory(options:isYesNo:)` — the
/// pure mapping from detected prompt options to the APNs notification category
/// whose registered action set the phone renders on the lock screen. (§3.2)
final class PushCategoryTests: XCTestCase {

    func test_twoOptions() {
        XCTAssertEqual(PushNotificationService.waitingCategory(options: [1, 2], isYesNo: false), "waiting.12")
    }

    func test_threeOptions() {
        XCTAssertEqual(PushNotificationService.waitingCategory(options: [1, 2, 3], isYesNo: false), "waiting.123")
    }

    func test_fourOptions() {
        XCTAssertEqual(PushNotificationService.waitingCategory(options: [1, 2, 3, 4], isYesNo: false), "waiting.1234")
    }

    func test_moreThanFourOptions_fallsBackToLegacy() {
        XCTAssertEqual(PushNotificationService.waitingCategory(options: [1, 2, 3, 4, 5], isYesNo: false), "waiting_for_input")
    }

    func test_singleOption_fallsBackToLegacy() {
        XCTAssertEqual(PushNotificationService.waitingCategory(options: [1], isYesNo: false), "waiting_for_input")
    }

    func test_yesNo_whenNoNumberedOptions() {
        XCTAssertEqual(PushNotificationService.waitingCategory(options: nil, isYesNo: true), "waiting.yn")
    }

    func test_numberedWins_overYesNo() {
        // A numbered Yes/No prompt (1. Yes / 2. No) is numbered, not free y/n.
        XCTAssertEqual(PushNotificationService.waitingCategory(options: [1, 2], isYesNo: true), "waiting.12")
    }

    func test_nothingDetected_fallsBackToLegacy() {
        XCTAssertEqual(PushNotificationService.waitingCategory(options: nil, isYesNo: false), "waiting_for_input")
    }
}
