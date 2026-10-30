import XCTest
@testable import Quip

/// A backup may only overwrite the phone's settings when it is newer than
/// the phone's own last edit (Q-63). This is the rule every restore path
/// goes through.
final class PreferencesFreshnessTests: XCTestCase {

    func test_freshInstall_takesAnyBackup() {
        XCTAssertTrue(PreferencesFreshness.shouldApply(snapshotSavedAt: nil, localModifiedAt: nil))
        XCTAssertTrue(PreferencesFreshness.shouldApply(snapshotSavedAt: 100, localModifiedAt: nil))
    }

    func test_editedPhone_rejectsOlderAndUnstampedCopies() {
        XCTAssertFalse(PreferencesFreshness.shouldApply(snapshotSavedAt: nil, localModifiedAt: 500),
                       "a copy from before stamps existed must not undo an edit")
        XCTAssertFalse(PreferencesFreshness.shouldApply(snapshotSavedAt: 400, localModifiedAt: 500))
        XCTAssertFalse(PreferencesFreshness.shouldApply(snapshotSavedAt: 500, localModifiedAt: 500),
                       "the same edit echoed back changes nothing")
    }

    func test_editedPhone_takesANewerCopy() {
        XCTAssertTrue(PreferencesFreshness.shouldApply(snapshotSavedAt: 501, localModifiedAt: 500))
    }

    func test_snapshotCarriesItsStampThroughJSON() throws {
        let blob = try JSONEncoder().encode(PreferencesSnapshot(quickSlotsJSON: "[]", savedAt: 1_700_000_000))
        let back = try JSONDecoder().decode(PreferencesSnapshot.self, from: blob)
        XCTAssertEqual(back.savedAt, 1_700_000_000)
        let old = try JSONDecoder().decode(PreferencesSnapshot.self, from: Data(#"{"quickSlotsJSON":"[]"}"#.utf8))
        XCTAssertNil(old.savedAt, "a copy made before the field existed decodes as unstamped")
    }

    func test_windowOrderModeRidesTheSnapshot() throws {
        // Q-88 US-004: the Recent / Manual choice survives a reinstall.
        let blob = try JSONEncoder().encode(PreferencesSnapshot(savedAt: 1, windowOrderMode: "manual"))
        XCTAssertEqual(try JSONDecoder().decode(PreferencesSnapshot.self, from: blob).windowOrderMode, "manual")
        let old = try JSONDecoder().decode(PreferencesSnapshot.self, from: Data(#"{"savedAt":1}"#.utf8))
        XCTAssertNil(old.windowOrderMode, "a backup from before the field leaves the phone's choice alone")
    }

    func test_windowOrderModeIsCaptured_andAJunkValueIsNot() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "PreferencesFreshnessTests.windowOrderMode"))
        defer { d.removePersistentDomain(forName: "PreferencesFreshnessTests.windowOrderMode") }
        XCTAssertNil(PreferencesSyncService.snapshot(from: d, savedAt: 1).windowOrderMode, "never chosen: not backed up")
        d.set("recent", forKey: PhoneWindowOrder.Mode.storageKey)
        XCTAssertEqual(PreferencesSyncService.snapshot(from: d, savedAt: 1).windowOrderMode, "recent")
        d.set("sideways", forKey: PhoneWindowOrder.Mode.storageKey)
        XCTAssertNil(PreferencesSyncService.snapshot(from: d, savedAt: 1).windowOrderMode)
    }
}
