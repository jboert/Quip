import Foundation

/// Whether this process is an XCTest host rather than the app a person uses.
///
/// The test host must never connect to a paired Mac. On 2026-10-07 the unit
/// suite's host app ran on a simulator that was still paired, authenticated
/// against the owner's Mac, and the Mac then broadcast the simulator's saved
/// settings to the owner's phone. Unit tests build their own objects and need
/// no live connection. The Mac app has the same guard in SingleInstanceGuard.
enum TestHostGuard {
    static let isRunningTests: Bool = isRunningTests(
        environment: ProcessInfo.processInfo.environment,
        xctestLoaded: NSClassFromString("XCTestCase") != nil)

    static func isRunningTests(environment: [String: String], xctestLoaded: Bool) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || xctestLoaded
    }
}
