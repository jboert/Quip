import XCTest
@testable import Quip

/// The "APNs not configured" skip line names which fields are empty. It used to
/// say only "not configured", so a push.log reader could not tell a missing Team
/// ID (which the .p8 import never fills) from a missing Key ID.
final class PushNotConfiguredLineTests: XCTestCase {

    func test_missingFields_namesEachEmptyFieldInOrder() {
        XCTAssertEqual(
            PushNotificationService.missingAPNsFields(keyId: "", teamId: "", bundleId: "com.quip.QuipiOS"),
            ["keyId", "teamId"])
        XCTAssertEqual(
            PushNotificationService.missingAPNsFields(keyId: "ABCDE12345", teamId: "", bundleId: ""),
            ["teamId", "bundleId"])
    }

    func test_missingFields_emptyWhenConfigured() {
        XCTAssertEqual(
            PushNotificationService.missingAPNsFields(keyId: "ABCDE12345", teamId: "TEAM123456", bundleId: "com.x"),
            [])
    }

    func test_skipLine_namesTheEventAndTheMissingFields() {
        let line = PushNotificationService.notConfiguredSkipLine(event: "waiting_for_input",
                                                                 missing: ["keyId", "teamId"])
        XCTAssertEqual(line,
                       "waiting_for_input skipped — APNs not configured (missing: keyId, teamId) in Settings → Notifications")
    }
}
