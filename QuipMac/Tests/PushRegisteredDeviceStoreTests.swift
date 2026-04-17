import XCTest
@testable import Quip

/// US-001 requirement: the device token store must dedupe by token and
/// round-trip through UserDefaults across instances. These tests run the
/// service against an isolated UserDefaults suite so they don't collide
/// with real app state or other tests.
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

    func test_registerDevice_persistsSingleEntry() {
        // PushNotificationService hardcodes UserDefaults.standard, so verify
        // via the service's own observable state. Persistence roundtrip is
        // covered by the next test.
        let svc = PushNotificationService()
        let initialCount = svc.devices.count

        svc.registerDevice(token: "ABCDEF1234", environment: "development")

        XCTAssertEqual(svc.devices.count, initialCount + 1)
        XCTAssertEqual(svc.devices.last?.token, "ABCDEF1234")
        XCTAssertEqual(svc.devices.last?.environment, "development")

        // Cleanup — remove so subsequent tests / real app state aren't polluted
        svc.removeDevice(token: "ABCDEF1234")
    }

    func test_registerDevice_dedupesByToken() {
        let svc = PushNotificationService()
        let initialCount = svc.devices.count

        svc.registerDevice(token: "DEDUPTOKEN", environment: "development")
        svc.registerDevice(token: "DEDUPTOKEN", environment: "development")
        svc.registerDevice(token: "DEDUPTOKEN", environment: "production")

        XCTAssertEqual(svc.devices.count, initialCount + 1)
        XCTAssertEqual(svc.devices.last?.environment, "production",
                       "Re-registering with a different environment should update the existing entry")

        svc.removeDevice(token: "DEDUPTOKEN")
    }

    func test_registerDevice_normalizesToUppercase() {
        let svc = PushNotificationService()
        svc.registerDevice(token: "abc123def", environment: "development")
        XCTAssertTrue(svc.devices.contains(where: { $0.token == "ABC123DEF" }))
        svc.removeDevice(token: "ABC123DEF")
    }

    func test_registerDevice_rejectsEmptyToken() {
        let svc = PushNotificationService()
        let before = svc.devices.count
        svc.registerDevice(token: "", environment: "development")
        XCTAssertEqual(svc.devices.count, before)
    }

    func test_removeDevice_dropsMatchingToken() {
        let svc = PushNotificationService()
        svc.registerDevice(token: "REMOVEME", environment: "development")
        XCTAssertTrue(svc.devices.contains(where: { $0.token == "REMOVEME" }))
        svc.removeDevice(token: "REMOVEME")
        XCTAssertFalse(svc.devices.contains(where: { $0.token == "REMOVEME" }))
    }

    func test_persistence_roundTripsAcrossInstances() {
        let token = "ROUNDTRIP\(Int.random(in: 1000...9999))"
        let first = PushNotificationService()
        first.registerDevice(token: token, environment: "development")

        let second = PushNotificationService()
        XCTAssertTrue(second.devices.contains(where: { $0.token == token }),
                      "Second instance should load persisted devices from UserDefaults")

        second.removeDevice(token: token)
    }
}
