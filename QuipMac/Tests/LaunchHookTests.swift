import XCTest
@testable import Quip

@MainActor
final class LaunchHookTests: XCTestCase {

    func testRunsWhenLaunchFinishesAfterRegistration() {
        let hook = LaunchHook()
        var runs = 0
        hook.register { runs += 1 }
        XCTAssertEqual(runs, 0, "must wait for launch to finish")
        hook.finishLaunching()
        XCTAssertEqual(runs, 1)
    }

    func testRunsAtOnceWhenRegisteredAfterLaunch() {
        let hook = LaunchHook()
        hook.finishLaunching()
        var runs = 0
        hook.register { runs += 1 }
        XCTAssertEqual(runs, 1)
    }

    func testLaunchWithNothingRegisteredIsHarmless() {
        LaunchHook().finishLaunching()
    }
}
