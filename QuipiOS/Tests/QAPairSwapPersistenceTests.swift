#if os(iOS)
import XCTest
@testable import Quip

@MainActor
final class QAPairSwapPersistenceTests: XCTestCase {

    /// Per-backend swap key namespacing — never collide between backends.
    func testSwapKeyIsPerBackend() {
        let s1 = BackendSession.swapKey(forBackendId: "backend-A")
        let s2 = BackendSession.swapKey(forBackendId: "backend-B")
        XCTAssertNotEqual(s1, s2)
        XCTAssertTrue(s1.contains("backend-A"))
        XCTAssertTrue(s2.contains("backend-B"))
    }

    /// Round-trip through UserDefaults under the per-backend key.
    func testSwapStateRoundTripsThroughUserDefaults() {
        let backendId = "test-backend-\(UUID().uuidString)"
        let key = BackendSession.swapKey(forBackendId: backendId)
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))

        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))

        UserDefaults.standard.removeObject(forKey: key)
    }
}
#endif
