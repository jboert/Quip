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

    func test_payload_replyOnly_whenNothingDetected() throws {
        let dict = PushNotificationService.buildPayload(
            windowId: "w", title: "Quip", body: "🤖",
            attentionCount: 1, sound: true, isYesNo: false,
            options: nil, promptFingerprint: nil
        )
        let aps = try XCTUnwrap(dict["aps"] as? [String: Any])
        XCTAssertEqual(aps["category"] as? String, "waiting.text")
        XCTAssertNil(dict["quip_options"])
        XCTAssertNil(dict["quip_prompt_fingerprint"])
    }

    func test_payload_tooManyOptions_isReplyOnly() throws {
        let dict = PushNotificationService.buildPayload(
            windowId: "w", title: "Quip", body: "🤖",
            attentionCount: 1, sound: true, isYesNo: false,
            options: [1, 2, 3, 4, 5], promptFingerprint: "x"
        )
        let aps = try XCTUnwrap(dict["aps"] as? [String: Any])
        XCTAssertEqual(aps["category"] as? String, "waiting.text")
        // Options still travel so the in-app view can render them all.
        XCTAssertEqual(dict["quip_options"] as? [Int], [1, 2, 3, 4, 5])
    }

    // MARK: Q-56 bundle fields

    func test_payload_bundleCarriesThreadLevelAndEveryWindow() throws {
        let dict = PushNotificationService.buildPayload(
            windowId: "w1", title: "2 waiting", body: "api, web",
            attentionCount: 2, sound: true, isYesNo: false,
            options: nil, promptFingerprint: nil,
            windowIds: ["w1", "w2"], threadId: "quip.MAC", interruptionLevel: "active"
        )
        let aps = try XCTUnwrap(dict["aps"] as? [String: Any])
        XCTAssertEqual(aps["thread-id"] as? String, "quip.MAC")
        XCTAssertEqual(aps["interruption-level"] as? String, "active")
        XCTAssertEqual(dict["quip_window_id"] as? String, "w1", "first window keeps the legacy key")
        XCTAssertEqual(dict["quip_window_ids"] as? [String], ["w1", "w2"])
    }

    func test_payload_singleWindowOmitsTheIdList() throws {
        let dict = PushNotificationService.buildPayload(
            windowId: "w1", title: "api", body: "Waiting for your answer",
            attentionCount: 1, sound: true, isYesNo: true,
            options: nil, promptFingerprint: "yn", windowIds: ["w1"], threadId: "quip.MAC",
            interruptionLevel: "time-sensitive"
        )
        XCTAssertNil(dict["quip_window_ids"])
        let aps = try XCTUnwrap(dict["aps"] as? [String: Any])
        XCTAssertEqual(aps["interruption-level"] as? String, "time-sensitive")
    }

    func test_digestText_namesTheWindowOrShowsThePromptOnlyWhenAsked() {
        let api = PushCoalescer.Wait(windowId: "a", windowName: "zsh — api", projectName: "api", options: nil,
                                     isYesNo: false, promptFingerprint: "f", promptPreview: "Apply the migration?")
        let plain = PushNotificationService.digestText([api], showPromptText: false)
        XCTAssertEqual(plain.title, "api")
        XCTAssertEqual(plain.body, "zsh — api is waiting for your answer")
        let shown = PushNotificationService.digestText([api], showPromptText: true)
        XCTAssertEqual(shown.body, "Apply the migration?")
        let noProject = PushCoalescer.Wait(windowId: "b", windowName: "Terminal", projectName: nil, options: nil,
                                           isYesNo: false, promptFingerprint: nil, promptPreview: nil)
        let fallback = PushNotificationService.digestText([noProject], showPromptText: true)
        XCTAssertEqual(fallback.title, "Terminal")
        XCTAssertEqual(fallback.body, "Waiting for your answer", "no preview: never an empty body")
    }

    func test_digestText_namesEachButton() {
        let labels = [1: "Yes", 2: "Yes, don't ask again", 3: "No", 4: "Type something"]
        let w = PushCoalescer.Wait(windowId: "a", windowName: "api", projectName: "api", options: [1, 2, 3],
                                   isYesNo: false, promptFingerprint: "f", promptPreview: "Run the migration?",
                                   optionLabels: labels)
        XCTAssertEqual(PushNotificationService.digestText([w], showPromptText: false).body,
                       "Waiting for your answer\n1 Yes · 2 Yes, don't ask again · 3 No",
                       "the free-text row (4) is not answerable, so it is not listed")
        XCTAssertEqual(PushNotificationService.digestText([w], showPromptText: true).body,
                       "Run the migration?\n1 Yes · 2 Yes, don't ask again · 3 No")
        XCTAssertNil(PushNotificationService.optionsLine(options: nil, labels: labels))
        XCTAssertNil(PushNotificationService.optionsLine(options: [1, 2], labels: nil))
        XCTAssertEqual(PushNotificationService.optionsLine(options: [1, 2, 3, 4, 5, 6],
                                                           labels: [1: "a", 2: "b", 3: "c", 4: "d", 5: "e", 6: "f"]),
                       "1 a · 2 b · 3 c · 4 d +2 more")
    }

    func test_digestText_bundleListsProjectsAndCountsTheRest() {
        func w(_ id: String, _ project: String?) -> PushCoalescer.Wait {
            PushCoalescer.Wait(windowId: id, windowName: id, projectName: project, options: nil,
                               isYesNo: id == "d", promptFingerprint: nil, promptPreview: "secret question")
        }
        let waits = [w("a", "api"), w("b", "web"), w("c", "api"), w("d", "db"), w("e", "ops")]
        let text = PushNotificationService.digestText(waits, showPromptText: true)
        XCTAssertEqual(text.title, "5 waiting")
        XCTAssertEqual(text.body, "api, web, db +1 more", "duplicates merged, prompt text never leaks into a bundle")
        XCTAssertEqual(PushNotificationService.interruptionLevel(for: waits), "time-sensitive")
        XCTAssertEqual(PushNotificationService.interruptionLevel(for: [w("a", "api")]), "active")
    }

    // MARK: swrm "story started" payload (US-005)

    func test_swrmPayload_titleBodyAndExtras() throws {
        let dict = PushNotificationService.buildSwrmPayload(
            project: "Quip", taskId: "42", title: "Add dark mode", sound: true)
        let aps = try XCTUnwrap(dict["aps"] as? [String: Any])
        let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
        XCTAssertEqual(alert["title"] as? String, "Started - Quip")
        XCTAssertEqual(alert["body"] as? String, "Add dark mode -> In Progress")
        XCTAssertEqual(aps["sound"] as? String, "default")
        XCTAssertEqual(dict["quip_event"] as? String, "swrm_story_started")
        XCTAssertEqual(dict["quip_swrm_task_id"] as? String, "42")
        // Not an attention-queue alert — no badge/category.
        XCTAssertNil(aps["badge"])
        XCTAssertNil(aps["category"])
        XCTAssertNil(dict["quip_window_id"])
    }

    func test_swrmPayload_soundFalse_omitsSound() throws {
        let dict = PushNotificationService.buildSwrmPayload(
            project: "swrm", taskId: "7", title: "Story #7", sound: false)
        let aps = try XCTUnwrap(dict["aps"] as? [String: Any])
        XCTAssertNil(aps["sound"])
        XCTAssertEqual(dict["quip_swrm_task_id"] as? String, "7")
    }
}
