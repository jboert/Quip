import XCTest
@testable import Quip

/// Migration + round-trip coverage for `APNsMetadataStore`.
/// Mirrors PINStoreTests structure. (GH #24, follow-up to GH #22.)
///
/// These tests must never reach the owner's login Keychain or com.quip.mac
/// defaults. Under XCTest the store reads and writes an in-memory backing, and
/// its migration uses a throwaway suite (`migrationDefaults`). This file used
/// to SecItemDelete the real keyId/teamId/bundleId items in every setUp and
/// tearDown, which is why push was dark from at least 2026-09-12 (board Q-48).
final class APNsMetadataStoreTests: XCTestCase {

    private static let legacyKeyId = "apnsKeyId"
    private static let legacyTeamId = "apnsTeamId"
    private static let legacyBundleId = "apnsBundleId"
    private static let migrationDoneKey = "apnsMetadataMigrationV1Done"

    private var defaults: UserDefaults { APNsMetadataStore.migrationDefaults }

    override func setUp() {
        super.setUp()
        // The in-memory backing is keyed on this; without it every call below
        // would go to the real Keychain.
        XCTAssertTrue(SingleInstanceGuard.isRunningTests)
        APNsMetadataStore.wipeForTests()
    }

    override func tearDown() {
        APNsMetadataStore.wipeForTests()
        super.tearDown()
    }

    // MARK: - Isolation

    func test_migrationDefaults_isNotTheOwnersDomain() {
        XCTAssertFalse(defaults === UserDefaults.standard,
                       "under XCTest the migration must use a throwaway suite, never com.quip.mac")
        let sentinel = "apnsMetadataIsolationSentinel"
        defaults.set("x", forKey: sentinel)
        defer { defaults.removeObject(forKey: sentinel) }
        XCTAssertNil(UserDefaults.standard.object(forKey: sentinel),
                     "a write to the migration suite must not show up in the owner's defaults")
    }

    // MARK: - Migration

    func test_migration_allLegacyValuesPresent_movesToKeychain() {
        defaults.set("ABC1234567", forKey: Self.legacyKeyId)
        defaults.set("D2PM6R797Q", forKey: Self.legacyTeamId)
        defaults.set("com.quip.QuipiOS", forKey: Self.legacyBundleId)

        XCTAssertEqual(APNsMetadataStore.keyId, "ABC1234567")
        XCTAssertEqual(APNsMetadataStore.teamId, "D2PM6R797Q")
        XCTAssertEqual(APNsMetadataStore.bundleId, "com.quip.QuipiOS")

        // Legacy keys purged.
        XCTAssertNil(defaults.string(forKey: Self.legacyKeyId))
        XCTAssertNil(defaults.string(forKey: Self.legacyTeamId))
        XCTAssertNil(defaults.string(forKey: Self.legacyBundleId))
    }

    func test_migration_partialLegacy_movesOnlyPresent() {
        // Only keyId in legacy storage; teamId and bundleId blank.
        defaults.set("KEY-ONLY", forKey: Self.legacyKeyId)

        XCTAssertEqual(APNsMetadataStore.keyId, "KEY-ONLY")
        XCTAssertEqual(APNsMetadataStore.teamId, "")
        // bundleId falls back to defaultBundleId when neither legacy nor
        // Keychain populated.
        XCTAssertEqual(APNsMetadataStore.bundleId, "com.quip.QuipiOS")
    }

    func test_migration_isIdempotent() {
        defaults.set("FIRST-KEY", forKey: Self.legacyKeyId)
        XCTAssertEqual(APNsMetadataStore.keyId, "FIRST-KEY")

        // Re-introduce a legacy value and confirm it doesn't replace.
        defaults.set("SHOULD-BE-IGNORED", forKey: Self.legacyKeyId)
        XCTAssertEqual(APNsMetadataStore.keyId, "FIRST-KEY",
                       "migrationDoneKey gates re-runs — Keychain wins after first migration")
    }

    func test_migration_keychainPrePopulated_doesNotOverwrite() {
        APNsMetadataStore.keyId = "FROM-KEYCHAIN"
        // Reset migration flag to simulate a partial-migration retry path.
        defaults.removeObject(forKey: Self.migrationDoneKey)
        defaults.set("FROM-LEGACY", forKey: Self.legacyKeyId)

        // Read forces migration check; Keychain is non-nil so legacy is
        // discarded but the original Keychain value stays.
        XCTAssertEqual(APNsMetadataStore.keyId, "FROM-KEYCHAIN",
                       "Existing Keychain value wins over a stray legacy value")
        XCTAssertNil(defaults.string(forKey: Self.legacyKeyId),
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

    func test_wipeForTests_clearsEveryField() {
        APNsMetadataStore.keyId = "K"
        APNsMetadataStore.teamId = "T"
        APNsMetadataStore.bundleId = "com.example.B"
        APNsMetadataStore.wipeForTests()
        XCTAssertEqual(APNsMetadataStore.keyId, "")
        XCTAssertEqual(APNsMetadataStore.teamId, "")
        XCTAssertEqual(APNsMetadataStore.bundleId, "com.quip.QuipiOS")
    }
}

/// `APNsKeyStore` under XCTest: the .p8 lives in an in-memory backing, so no
/// test can read, replace or delete the owner's real key.
final class APNsKeyStoreTestBackingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        XCTAssertTrue(SingleInstanceGuard.isRunningTests)
        APNsKeyStore.wipeForTests()
    }

    override func tearDown() {
        APNsKeyStore.wipeForTests()
        super.tearDown()
    }

    func test_startsEmpty() {
        XCTAssertNil(APNsKeyStore.get())
        XCTAssertFalse(APNsKeyStore.hasKey)
    }

    func test_setGetClear_roundTrip() {
        let pem = Data("not a real key".utf8)
        XCTAssertTrue(APNsKeyStore.set(pem))
        XCTAssertEqual(APNsKeyStore.get(), pem)
        XCTAssertTrue(APNsKeyStore.hasKey)

        XCTAssertTrue(APNsKeyStore.clear())
        XCTAssertNil(APNsKeyStore.get())
    }

    func test_setReplacesThePreviousValue() {
        APNsKeyStore.set(Data("first".utf8))
        APNsKeyStore.set(Data("second".utf8))
        XCTAssertEqual(APNsKeyStore.get(), Data("second".utf8))
    }
}

/// The push.log wording that tells "never stored" from "Keychain refused".
final class APNsKeychainLogTests: XCTestCase {

    func test_describe_namesAbsentWithItsStatus() {
        XCTAssertEqual(APNsKeychainLog.describe(errSecItemNotFound), "absent (-25300)")
    }

    func test_describe_otherFailuresAreNotCalledAbsent() {
        let line = APNsKeychainLog.describe(errSecInteractionNotAllowed)
        XCTAssertTrue(line.hasPrefix("failed (-25308"), line)
        XCTAssertFalse(line.contains("absent"))
    }

    func test_describe_success() {
        XCTAssertEqual(APNsKeychainLog.describe(errSecSuccess), "ok")
    }

    func test_shouldLogRead_isEdgeTriggered() {
        // First read: a failure is news, a success is not.
        XCTAssertTrue(APNsKeychainLog.shouldLogRead(previous: nil, current: errSecItemNotFound))
        XCTAssertFalse(APNsKeychainLog.shouldLogRead(previous: nil, current: errSecSuccess))
        // The same failure again stays quiet; every waiting event reads all three fields.
        XCTAssertFalse(APNsKeychainLog.shouldLogRead(previous: errSecItemNotFound, current: errSecItemNotFound))
        // A different failure is news.
        XCTAssertTrue(APNsKeychainLog.shouldLogRead(previous: errSecItemNotFound, current: errSecInteractionNotAllowed))
        // Recovery is logged once, then steady state is quiet.
        XCTAssertTrue(APNsKeychainLog.shouldLogRead(previous: errSecItemNotFound, current: errSecSuccess))
        XCTAssertFalse(APNsKeychainLog.shouldLogRead(previous: errSecSuccess, current: errSecSuccess))
    }
}
