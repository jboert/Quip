import XCTest
@testable import Quip

/// Migration + Keychain round-trip coverage for `PINStore`.
/// See docs/security/2026-05-06-cloudflared-process-audit.md (GH #14).
///
/// These tests touch the real Keychain. Each test wipes both the
/// service entry and the legacy UserDefaults key in setUp/tearDown so
/// they don't depend on order or pollute the user's actual login
/// keychain entries.
final class PINStoreTests: XCTestCase {

    private static let legacyDefaultKey = "QuipAuthPIN"

    override func setUp() {
        super.setUp()
        PINStore.wipeForTests()
    }

    override func tearDown() {
        PINStore.wipeForTests()
        super.tearDown()
    }

    // MARK: - Migration

    func test_migration_legacyValuePresent_movesToKeychain() {
        UserDefaults.standard.set("123456", forKey: Self.legacyDefaultKey)

        // First read triggers migration.
        let pin = PINStore.pin
        XCTAssertEqual(pin, "123456")

        // Legacy key purged.
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.legacyDefaultKey))
    }

    func test_migration_legacyEmpty_doesNotPopulateKeychain() {
        UserDefaults.standard.set("", forKey: Self.legacyDefaultKey)

        XCTAssertNil(PINStore.pin)
    }

    func test_migration_isIdempotent() {
        UserDefaults.standard.set("999000", forKey: Self.legacyDefaultKey)
        XCTAssertEqual(PINStore.pin, "999000")

        // Second read goes straight to Keychain — even if a malicious
        // legacy value lands back in UserDefaults, migration is done.
        UserDefaults.standard.set("attacker_inserted", forKey: Self.legacyDefaultKey)
        PINStore.performMigrationIfNeeded()
        XCTAssertEqual(PINStore.pin, "999000",
                       "Migration must run only once per install — re-running on a populated Keychain must not overwrite")
    }

    func test_migration_keychainAlreadyPopulated_doesNotOverwrite() {
        // Pre-populate Keychain.
        PINStore.pin = "keychainPin"
        // Reset the migration flag so performMigrationIfNeeded re-runs
        // (simulating an upgrade path where someone hand-set both).
        PINStore.resetMigrationFlagForTests()
        UserDefaults.standard.set("legacyPin", forKey: Self.legacyDefaultKey)

        PINStore.performMigrationIfNeeded()
        XCTAssertEqual(PINStore.pin, "keychainPin",
                       "Existing Keychain value wins over a stray legacy value")
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.legacyDefaultKey),
                     "Legacy key still purged on migration so it doesn't sit there as a plaintext copy")
    }

    // MARK: - Round trip

    func test_roundTrip_writeThenRead() {
        PINStore.pin = "abc123"
        XCTAssertEqual(PINStore.pin, "abc123")
    }

    func test_roundTrip_overwrite() {
        PINStore.pin = "first"
        PINStore.pin = "second"
        XCTAssertEqual(PINStore.pin, "second")
    }

    func test_roundTrip_setNil_clearsValue() {
        PINStore.pin = "transient"
        PINStore.pin = nil
        XCTAssertNil(PINStore.pin)
    }

    func test_roundTrip_setEmpty_clearsValue() {
        PINStore.pin = "transient"
        PINStore.pin = ""
        XCTAssertNil(PINStore.pin,
                     "Empty string is treated as a clear, not a stored empty value — paired devices need a real PIN or no PIN at all")
    }

    // MARK: - Generated PIN entropy

    @MainActor
    func test_freshInstall_pinManager_generates8DigitPIN() {
        // PINStore is empty, no legacy value → PINManager.init() generates.
        let manager = PINManager()
        XCTAssertEqual(manager.pin.count, 8,
                       "GH #14 raises entropy: new PINs are 8 digits")
        XCTAssertNotNil(Int(manager.pin),
                        "Generated PIN must parse as integer (digits only)")
    }

    @MainActor
    func test_regenerate_producesNewPIN() {
        let manager = PINManager()
        let first = manager.pin
        manager.regeneratePIN()
        let second = manager.pin
        // Tiny chance of collision (1 in 1e8) but worth catching the
        // bug where regenerate becomes a no-op.
        XCTAssertNotEqual(first, second,
                          "regeneratePIN must produce a fresh value — collision odds 1 in 10^8")
    }

    @MainActor
    func test_existing6DigitPIN_preservedThroughMigration() {
        // Simulate a user upgrading from the UserDefaults era. Their
        // paired iOS device knows the 6-digit PIN; we can't break that.
        UserDefaults.standard.set("424242", forKey: Self.legacyDefaultKey)

        let manager = PINManager()
        XCTAssertEqual(manager.pin, "424242",
                       "Existing 6-digit PIN must survive migration so paired devices keep working")
    }
}
