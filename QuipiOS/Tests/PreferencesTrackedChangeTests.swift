import XCTest
@testable import Quip

/// Only a change to a backed-up setting is the user's edit. The app writes
/// other keys all the time (window order per layout, the recency stack per
/// Mac focus change); those must not stamp a local edit, or a backup restore
/// after a reinstall is refused as older.
final class PreferencesTrackedChangeTests: XCTestCase {
    private var suiteName: String!
    private var d: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PreferencesTrackedChangeTests.\(UUID().uuidString)"
        d = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        d.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_untrackedWrites_leaveTheTrackedSettingsEqual() {
        let before = PreferencesSyncService.trackedPreferences(in: d)
        d.set(#"["a","b"]"#, forKey: "phoneWindowOrderJSON")
        d.set(["w1", "w2"], forKey: WindowSelectionMemory.key(forBackendId: "mac"))
        XCTAssertEqual(PreferencesSyncService.trackedPreferences(in: d), before)
    }

    func test_aBackedUpSetting_isATrackedChange() {
        let before = PreferencesSyncService.trackedPreferences(in: d)
        d.set(false, forKey: "followFrontmost")
        let after = PreferencesSyncService.trackedPreferences(in: d)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.followFrontmost, false)
    }

    func test_twoReadsWithNoChange_areEqual() {
        d.set("manual", forKey: PhoneWindowOrder.Mode.storageKey)
        XCTAssertEqual(PreferencesSyncService.trackedPreferences(in: d),
                       PreferencesSyncService.trackedPreferences(in: d),
                       "the stamp must not make every read differ")
    }
}
