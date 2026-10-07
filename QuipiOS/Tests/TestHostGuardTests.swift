import XCTest
@testable import Quip

/// The phone app must know when it is only an XCTest host, so it never
/// connects to a paired Mac from a test run.
final class TestHostGuardTests: XCTestCase {

    func test_plainLaunchIsNotATestRun() {
        XCTAssertFalse(TestHostGuard.isRunningTests(environment: [:], xctestLoaded: false))
        XCTAssertFalse(TestHostGuard.isRunningTests(environment: ["HOME": "/x"], xctestLoaded: false))
    }

    func test_xctestEnvironmentOrFrameworkMeansATestRun() {
        XCTAssertTrue(TestHostGuard.isRunningTests(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"], xctestLoaded: false))
        XCTAssertTrue(TestHostGuard.isRunningTests(
            environment: ["XCTestSessionIdentifier": "ABC"], xctestLoaded: false))
        XCTAssertTrue(TestHostGuard.isRunningTests(environment: [:], xctestLoaded: true))
    }

    func test_thisSuiteIsDetectedAsATestRun() {
        XCTAssertTrue(TestHostGuard.isRunningTests)
    }
}
