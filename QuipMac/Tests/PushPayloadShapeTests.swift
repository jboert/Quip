import XCTest
@testable import Quip

/// Locks the APNs payload shape (#4). The phone consumes `aps.category` to
/// pick its registered action set, plus top-level `quip_*` extras.
final class PushPayloadShapeTests: XCTestCase {

    func test_payload_includesOptionsAndFingerprint_threeChoices() throws {
        let dict = PushNotificationService.buildPayload(
            windowId: "w1", title: "Quip", body: "🤖 AI is waiting",
            attentionCount: 1, sound: true, isYesNo: false,
            options: [1, 2, 3], promptFingerprint: "abc123"
        )
        let aps = try XCTUnwrap(dict["aps"] as? [String: Any])
        XCTAssertEqual(aps["category"] as? String, "waiting.123")
        XCTAssertEqual(aps["badge"] as? Int, 1)
        XCTAssertEqual(aps["sound"] as? String, "default")
        XCTAssertEqual(dict["quip_window_id"] as? String, "w1")
        XCTAssertEqual(dict["quip_options"] as? [Int], [1, 2, 3])
        XCTAssertEqual(dict["quip_prompt_fingerprint"] as? String, "abc123")
    }

    func test_payload_yesNoCategory() throws {
        let dict = PushNotificationService.buildPayload(
            windowId: "w", title: "Quip", body: "🤖",
            attentionCount: 1, sound: false, isYesNo: true,
            options: nil, promptFingerprint: "yn1"
        )
        let aps = try XCTUnwrap(dict["aps"] as? [String: Any])
        XCTAssertEqual(aps["category"] as? String, "waiting.yn")
        XCTAssertNil(aps["sound"])  // sound:false omitted
        XCTAssertEqual(dict["quip_prompt_fingerprint"] as? String, "yn1")
        XCTAssertNil(dict["quip_options"])
    }

    func test_payload_legacyFallback_whenNothingDetected() throws {
        let dict = PushNotificationService.buildPayload(
            windowId: "w", title: "Quip", body: "🤖",
            attentionCount: 1, sound: true, isYesNo: false,
            options: nil, promptFingerprint: nil
        )
        let aps = try XCTUnwrap(dict["aps"] as? [String: Any])
        XCTAssertEqual(aps["category"] as? String, "waiting_for_input")
        XCTAssertNil(dict["quip_options"])
        XCTAssertNil(dict["quip_prompt_fingerprint"])
    }

    func test_payload_tooManyOptions_fallsBackToLegacy() throws {
        let dict = PushNotificationService.buildPayload(
            windowId: "w", title: "Quip", body: "🤖",
            attentionCount: 1, sound: true, isYesNo: false,
            options: [1, 2, 3, 4, 5], promptFingerprint: "x"
        )
        let aps = try XCTUnwrap(dict["aps"] as? [String: Any])
        XCTAssertEqual(aps["category"] as? String, "waiting_for_input")
        // Options still travel so the in-app view can render them all.
        XCTAssertEqual(dict["quip_options"] as? [Int], [1, 2, 3, 4, 5])
    }
}
