import XCTest
@testable import Quip

/// US-001 requirement: the device token store must dedupe by token and
/// round-trip through UserDefaults across instances. These tests run the
/// service against an isolated UserDefaults suite so they don't collide
/// with real app state or other tests.
///
/// The suite has to be passed in: the Mac suite is app-hosted with the real
/// bundle id, so `UserDefaults.standard` here is the owner's com.quip.mac
/// domain. These tests used to register and remove ROUNDTRIP…, REMOVEME and
/// DEDUPTOKEN in the owner's live `registeredPushDevices` list.
@MainActor
final class PushRegisteredDeviceStoreTests: XCTestCase {

    // Use a unique suite per test so parallel runs don't step on each other.
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "PushRegisteredDeviceStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func test_defaultStore_isNotTheOwnersDomainUnderTests() {
        XCTAssertTrue(SingleInstanceGuard.isRunningTests)
        XCTAssertFalse(PushNotificationService.defaultStore === UserDefaults.standard,
                       "a service built without an explicit suite must still stay out of com.quip.mac")
    }

    func test_registerDevice_persistsSingleEntry() {
        let svc = PushNotificationService(defaults: defaults)
        XCTAssertTrue(svc.devices.isEmpty, "a fresh suite starts with no devices")

        svc.registerDevice(token: "ABCDEF1234", environment: "development")

        XCTAssertEqual(svc.devices.count, 1)
        XCTAssertEqual(svc.devices.last?.token, "ABCDEF1234")
        XCTAssertEqual(svc.devices.last?.environment, "development")
        XCTAssertNotNil(defaults.data(forKey: "registeredPushDevices"),
                        "the registry persists to the injected suite")
    }

    func test_registerDevice_dedupesByToken() {
        let svc = PushNotificationService(defaults: defaults)

        svc.registerDevice(token: "DEDUPTOKEN", environment: "development")
        svc.registerDevice(token: "DEDUPTOKEN", environment: "development")
        svc.registerDevice(token: "DEDUPTOKEN", environment: "production")

        XCTAssertEqual(svc.devices.count, 1)
        XCTAssertEqual(svc.devices.last?.environment, "production",
                       "Re-registering with a different environment should update the existing entry")
    }

    func test_registerDevice_normalizesToUppercase() {
        let svc = PushNotificationService(defaults: defaults)
        svc.registerDevice(token: "abc123def", environment: "development")
        XCTAssertTrue(svc.devices.contains(where: { $0.token == "ABC123DEF" }))
    }

    func test_registerDevice_rejectsEmptyToken() {
        let svc = PushNotificationService(defaults: defaults)
        svc.registerDevice(token: "", environment: "development")
        XCTAssertTrue(svc.devices.isEmpty)
    }

    func test_removeDevice_dropsMatchingToken() {
        let svc = PushNotificationService(defaults: defaults)
        svc.registerDevice(token: "REMOVEME", environment: "development")
        XCTAssertTrue(svc.devices.contains(where: { $0.token == "REMOVEME" }))
        svc.removeDevice(token: "REMOVEME")
        XCTAssertFalse(svc.devices.contains(where: { $0.token == "REMOVEME" }))
    }

    func test_persistence_roundTripsAcrossInstances() {
        let token = "ROUNDTRIP\(Int.random(in: 1000...9999))"
        let first = PushNotificationService(defaults: defaults)
        first.registerDevice(token: token, environment: "development")

        let second = PushNotificationService(defaults: defaults)
        XCTAssertTrue(second.devices.contains(where: { $0.token == token }),
                      "Second instance should load persisted devices from UserDefaults")
    }
}
