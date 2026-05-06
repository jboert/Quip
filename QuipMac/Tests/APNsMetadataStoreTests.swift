import XCTest
@testable import Quip

/// Migration + Keychain round-trip coverage for `APNsMetadataStore`.
/// Mirrors PINStoreTests structure. (GH #24, follow-up to GH #22.)
///
/// These tests touch the real Keychain. Each test wipes both the
/// service entry and the legacy UserDefaults keys in setUp/tearDown.
final class APNsMetadataStoreTests: XCTestCase {

    private static let legacyKeyId = "apnsKeyId"
    private static let legacyTeamId = "apnsTeamId"
    private static let legacyBundleId = "apnsBundleId"
    private static let migrationDoneKey = "apnsMetadataMigrationV1Done"
    private static let service = "com.quip.mac.apns-metadata"

    override func setUp() {
        super.setUp()
        wipeKeychainAndDefaults()
    }

    override func tearDown() {
        wipeKeychainAndDefaults()
        super.tearDown()
    }

    // MARK: - Migration

    func test_migration_allLegacyValuesPresent_movesToKeychain() {
        UserDefaults.standard.set("ABC1234567", forKey: Self.legacyKeyId)
        UserDefaults.standard.set("D2PM6R797Q", forKey: Self.legacyTeamId)
        UserDefaults.standard.set("com.quip.QuipiOS", forKey: Self.legacyBundleId)

        XCTAssertEqual(APNsMetadataStore.keyId, "ABC1234567")
        XCTAssertEqual(APNsMetadataStore.teamId, "D2PM6R797Q")
        XCTAssertEqual(APNsMetadataStore.bundleId, "com.quip.QuipiOS")

        // Legacy keys purged.
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.legacyKeyId))
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.legacyTeamId))
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.legacyBundleId))
    }

    func test_migration_partialLegacy_movesOnlyPresent() {
        // Only keyId in legacy storage; teamId and bundleId blank.
        UserDefaults.standard.set("KEY-ONLY", forKey: Self.legacyKeyId)

        XCTAssertEqual(APNsMetadataStore.keyId, "KEY-ONLY")
        XCTAssertEqual(APNsMetadataStore.teamId, "")
        // bundleId falls back to defaultBundleId when neither legacy nor
        // Keychain populated.
        XCTAssertEqual(APNsMetadataStore.bundleId, "com.quip.QuipiOS")
    }

    func test_migration_isIdempotent() {
        UserDefaults.standard.set("FIRST-KEY", forKey: Self.legacyKeyId)
        XCTAssertEqual(APNsMetadataStore.keyId, "FIRST-KEY")

        // Re-introduce a legacy value and confirm it doesn't replace.
        UserDefaults.standard.set("SHOULD-BE-IGNORED", forKey: Self.legacyKeyId)
        XCTAssertEqual(APNsMetadataStore.keyId, "FIRST-KEY",
                       "migrationDoneKey gates re-runs — Keychain wins after first migration")
    }

    func test_migration_keychainPrePopulated_doesNotOverwrite() {
        APNsMetadataStore.keyId = "FROM-KEYCHAIN"
        // Reset migration flag to simulate a partial-migration retry path.
        UserDefaults.standard.removeObject(forKey: Self.migrationDoneKey)
        UserDefaults.standard.set("FROM-LEGACY", forKey: Self.legacyKeyId)

        // Read forces migration check; Keychain is non-nil so legacy is
        // discarded but the original Keychain value stays.
        XCTAssertEqual(APNsMetadataStore.keyId, "FROM-KEYCHAIN",
                       "Existing Keychain value wins over a stray legacy value")
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.legacyKeyId),
                     "Legacy key still purged on migration so it doesn't sit there as a plaintext copy")
    }

    // MARK: - Round trip

    func test_keyId_roundTrip() {
        APNsMetadataStore.keyId = "K1"
        XCTAssertEqual(APNsMetadataStore.keyId, "K1")
        APNsMetadataStore.keyId = "K2"
        XCTAssertEqual(APNsMetadataStore.keyId, "K2")
    }

    func test_teamId_roundTrip() {
        APNsMetadataStore.teamId = "T1"
        XCTAssertEqual(APNsMetadataStore.teamId, "T1")
    }

    func test_bundleId_roundTripAndDefault() {
        // Default when nothing stored.
        XCTAssertEqual(APNsMetadataStore.bundleId, "com.quip.QuipiOS")

        APNsMetadataStore.bundleId = "com.example.OtherApp"
        XCTAssertEqual(APNsMetadataStore.bundleId, "com.example.OtherApp")
    }

    func test_emptyValueWritten_isReadAsEmpty() {
        // Per APNsMetadataStore comment: empty string round-trips
        // (UI-bind sees "" not nil for non-bundleId fields).
        APNsMetadataStore.keyId = ""
        XCTAssertEqual(APNsMetadataStore.keyId, "")
    }

    // MARK: - Helpers

    private func wipeKeychainAndDefaults() {
        for account in ["keyId", "teamId", "bundleId"] {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(q as CFDictionary)
        }
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.legacyKeyId)
        d.removeObject(forKey: Self.legacyTeamId)
        d.removeObject(forKey: Self.legacyBundleId)
        d.removeObject(forKey: Self.migrationDoneKey)
    }
}
