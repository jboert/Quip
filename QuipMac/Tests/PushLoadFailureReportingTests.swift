import XCTest
@testable import Quip

/// Swallowed-error audit (2026-07-13): `loadDevices()` / `loadPreferences()`
/// used to decode with `try?`, so a corrupt or schema-drifted blob in
/// UserDefaults silently produced an empty map.
///
/// The consequences are both invisible AND total:
///   - empty `devices`     → every `notify*` path hits its
///                           `guard !devices.isEmpty else { return }` and push
///                           goes 100% dead, with nothing logged anywhere.
///   - empty `preferences` → Mac falls back to `.defaults` (paused=false), so
///                           the user's "Pause All" stops being honored and
///                           push fires anyway. This one actually shipped —
///                           see `DevicePushPreferencesDecodingTests`.
///
/// The loaders now report through `QuipLog` instead. These tests lock the
/// *reporting* contract on the pure decode seam: a bad blob must surface a
/// non-nil failure reason, and a good blob must not invent one.
final class PushLoadFailureReportingTests: XCTestCase {

    // MARK: - devices

    func test_decodeDevices_corruptBlob_reportsFailureInsteadOfEmptyList() {
        let (value, failure) = PushNotificationService.decodeDevices(Data("not json".utf8))
        XCTAssertNil(value, "a corrupt blob must not masquerade as a valid device list")
        XCTAssertNotNil(failure, "the decode error must be surfaced, not swallowed")
    }

    func test_decodeDevices_wrongShape_reportsFailure() {
        // Right JSON, wrong schema — the shape a real schema drift produces.
        let (value, failure) = PushNotificationService.decodeDevices(Data(#"{"token":"abc"}"#.utf8))
        XCTAssertNil(value)
        XCTAssertNotNil(failure, "schema drift must be reported — this is the bug that shipped")
    }

    func test_decodeDevices_validBlob_roundTripsWithNoFailure() throws {
        let devices = [RegisteredPushDevice(token: "ABC123", environment: "production",
                                            registeredAt: Date(timeIntervalSince1970: 0))]
        let data = try JSONEncoder().encode(devices)

        let (value, failure) = PushNotificationService.decodeDevices(data)
        XCTAssertNil(failure, "a healthy blob must not report a failure")
        XCTAssertEqual(value?.count, 1)
        XCTAssertEqual(value?.first?.token, "ABC123")
    }

    // MARK: - preferences

    func test_decodePreferences_corruptBlob_reportsFailureInsteadOfDefaults() {
        let (value, failure) = PushNotificationService.decodePreferences(Data("{{{".utf8))
        XCTAssertNil(value, "corrupt prefs must not silently become .defaults (paused=false)")
        XCTAssertNotNil(failure, "the decode error must be surfaced, not swallowed")
    }

    func test_decodePreferences_validBlob_preservesPaused() throws {
        let prefs = ["TOKEN": DevicePushPreferences(paused: true)]
        let data = try JSONEncoder().encode(prefs)

        let (value, failure) = PushNotificationService.decodePreferences(data)
        XCTAssertNil(failure, "a healthy blob must not report a failure")
        XCTAssertEqual(value?["TOKEN"]?.paused, true, "paused must survive the round-trip")
    }

    /// The decoder is deliberately tolerant of *missing* fields (that's what
    /// `DevicePushPreferences.init(from:)` is for). Tolerance must not be
    /// mistaken for a failure — otherwise the fix would log noise on every
    /// launch, which is the disease this audit is curing.
    func test_decodePreferences_oldSchemaMissingFields_isNotReportedAsFailure() {
        let json = #"{"TOKEN":{"paused":true,"sound":true}}"#
        let (value, failure) = PushNotificationService.decodePreferences(Data(json.utf8))
        XCTAssertNil(failure, "a tolerated old schema is NOT an error and must stay quiet")
        XCTAssertEqual(value?["TOKEN"]?.paused, true)
    }
}
