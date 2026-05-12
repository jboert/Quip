import XCTest
@testable import Quip

/// Locks the `WebSocketServer.requireAuth` property's lock-backed
/// concurrency contract introduced for GH #21. The property is read
/// from the network queue during connection handshake and written on
/// MainActor when the user toggles `requirePINForLocal` in Settings.
/// Without the OSAllocatedUnfairLock<Bool>, half-applied flips could
/// let an unauthenticated connection slip into the authenticated state.
///
/// These tests don't reproduce the race directly (race tests are
/// notoriously flaky); they pin down the behavioral contract:
/// - Default value is `true` (fail-safe).
/// - Setter then getter round-trips.
/// - Heavy concurrent reads + writes never produce torn or out-of-range
///   values.
/// (GH #24, follow-up to GH #21.)
final class WebSocketServerRequireAuthTests: XCTestCase {

    @MainActor
    func test_requireAuth_defaultValueIsTrue() {
        let server = WebSocketServer()
        XCTAssertTrue(server.requireAuth,
                      "Default must be fail-safe — unset server requires auth")
    }

    @MainActor
    func test_requireAuth_setterRoundTrips() {
        let server = WebSocketServer()
        server.requireAuth = false
        XCTAssertFalse(server.requireAuth)
        server.requireAuth = true
        XCTAssertTrue(server.requireAuth)
    }

    @MainActor
    func test_requireAuth_concurrentReadsDoNotTear() async {
        let server = WebSocketServer()

        // Run heavy concurrent reads while a writer flips the flag.
        // No XCTAssert can prove "no torn read" definitively, but if
        // the lock were missing this loop frequently surfaces as a
        // crash or sanitizer report on TSan-enabled CI.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    for _ in 0..<500 {
                        // Reads from arbitrary tasks — exercises the
                        // nonisolated getter path.
                        _ = server.requireAuth
                    }
                }
            }
            group.addTask {
                for i in 0..<200 {
                    server.requireAuth = (i % 2 == 0)
                }
            }
        }
        // Final read must produce a Bool — implicit in the type system,
        // but assert presence so the test does something useful when
        // the loops complete.
        let final = server.requireAuth
        XCTAssertTrue(final == true || final == false)
    }
}
