import XCTest
@testable import Quip

/// Regression tests for `DevicePushPreferences` Codable backwards-compat.
/// (wishlist §15 follow-up.)
///
/// Originally a default-synth Codable struct. Adding a new
/// `var foo: Bool = false` made every PRIOR persisted prefs row fail
/// to decode, because Codable synthesis requires non-Optional fields.
/// `loadPreferences()` swallowed the error via `try?`, the in-memory
/// preferences map went empty, and the Mac fell back to `.defaults`
/// (paused=false). Symptom: user toggled "Pause All" → push still
/// fired → Apple Watch mirrored the alerts → user couldn't silence
/// notifications even with pause on.
///
/// Custom `init(from:)` defaults missing fields. These tests lock the
/// behavior so the next "add a new toggle" change can't regress it.
final class DevicePushPreferencesDecodingTests: XCTestCase {

    func test_decodeOldJSON_withoutNotifyAllWindows_preservesPaused() throws {
        // Schema as it existed BEFORE notifyAllWindows landed.
        let json = """
        {
            "paused": true,
            "sound": true,
            "foregroundBanner": false,
            "bannerEnabled": true
        }
        """
        let data = Data(json.utf8)
        let prefs = try JSONDecoder().decode(DevicePushPreferences.self, from: data)
        XCTAssertTrue(prefs.paused, "paused must round-trip from old schema")
        XCTAssertFalse(prefs.notifyAllWindows, "missing field must default false")
    }

    func test_decodeMinimalJSON_appliesAllDefaults() throws {
        let json = "{}"
        let data = Data(json.utf8)
        let prefs = try JSONDecoder().decode(DevicePushPreferences.self, from: data)
        XCTAssertFalse(prefs.paused)
        XCTAssertTrue(prefs.sound)
        XCTAssertTrue(prefs.bannerEnabled)
        XCTAssertFalse(prefs.foregroundBanner)
        XCTAssertFalse(prefs.notifyAllWindows)
        XCTAssertNil(prefs.quietHoursStart)
        XCTAssertNil(prefs.quietHoursEnd)
        XCTAssertNil(prefs.timeZone)
    }

    func test_decodeFullJSON_preservesEveryField() throws {
        let original = DevicePushPreferences(
            paused: true,
            quietHoursStart: 22,
            quietHoursEnd: 7,
            sound: false,
            foregroundBanner: true,
            bannerEnabled: false,
            timeZone: "America/Phoenix",
            notifyAllWindows: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DevicePushPreferences.self, from: data)
        XCTAssertEqual(decoded, original, "round-trip must preserve every field")
    }

    func test_decodeBatchedDictionary_failsOpen() throws {
        // The real persistence shape is `[String: DevicePushPreferences]`.
        // Even one bad row would have failed the whole map under the
        // synthesized init. Verify the dictionary path also tolerates
        // mixed old + new schemas.
        let json = """
        {
            "OLDTOKEN": { "paused": true, "sound": true, "foregroundBanner": false, "bannerEnabled": true },
            "NEWTOKEN": { "paused": false, "sound": true, "foregroundBanner": false, "bannerEnabled": true, "notifyAllWindows": true }
        }
        """
        let data = Data(json.utf8)
        let map = try JSONDecoder().decode([String: DevicePushPreferences].self, from: data)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["OLDTOKEN"]?.paused, true)
        XCTAssertEqual(map["OLDTOKEN"]?.notifyAllWindows, false, "old row defaults missing field")
        XCTAssertEqual(map["NEWTOKEN"]?.notifyAllWindows, true)
    }
}
