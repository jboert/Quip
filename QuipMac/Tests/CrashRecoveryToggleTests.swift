import XCTest
@testable import Quip

/// The Reliability toggle stores whatever `CrashRecoveryToggle.resolve` settles
/// on. A refused install or uninstall must flip the toggle back and say which
/// one failed, or the switch shows a state launchd never reached.
final class CrashRecoveryToggleTests: XCTestCase {

    private struct Refused: LocalizedError {
        var errorDescription: String? { "launchd said no" }
    }

    func test_failedInstall_revertsToOffAndSaysInstall() throws {
        let result = CrashRecoveryToggle.resolve(requested: true) { _ in throw Refused() }
        XCTAssertFalse(result.enabled)
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.contains("install"), error)
        XCTAssertTrue(error.contains("launchd said no"), error)
    }

    func test_failedRemove_revertsToOnAndSaysRemove() throws {
        let result = CrashRecoveryToggle.resolve(requested: false) { _ in throw Refused() }
        XCTAssertTrue(result.enabled)
        let error = try XCTUnwrap(result.error)
        XCTAssertTrue(error.contains("remove"), error)
    }

    func test_success_keepsTheRequestAndAppliesItOnce() {
        for requested in [true, false] {
            var calls: [Bool] = []
            let result = CrashRecoveryToggle.resolve(requested: requested) { calls.append($0) }
            XCTAssertEqual(result.enabled, requested)
            XCTAssertNil(result.error)
            XCTAssertEqual(calls, [requested])
        }
    }
}
