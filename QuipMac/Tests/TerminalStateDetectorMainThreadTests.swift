import XCTest
@testable import Quip

/// Regression cover for the main-thread `ps` forks that produced macOS hang
/// reports up to 913 seconds (`Quip_2026-08-01-131028.hang`). Every path in
/// here is reachable from the MainActor; none of them may fork a subprocess.
@MainActor
final class TerminalStateDetectorMainThreadTests: XCTestCase {

    private var detector: TerminalStateDetector!

    override func setUpWithError() throws {
        detector = TerminalStateDetector()
        TerminalStateDetector.resetMainThreadProcessSpawnCount()
    }

    override func tearDownWithError() throws {
        detector.stopMonitoring()
        detector = nil
    }

    /// `refreshCLIKind` is called synchronously from the press_return and
    /// image_upload handlers on main. It must answer from the poll loop's
    /// snapshot, never by forking `ps` itself.
    func test_refreshCLIKind_doesNotSpawnProcessOnMainThread() {
        detector.trackWindow("w1", shellPid: 1, tty: nil)
        TerminalStateDetector.resetMainThreadProcessSpawnCount()

        _ = detector.refreshCLIKind(for: "w1")

        XCTAssertEqual(
            TerminalStateDetector.mainThreadProcessSpawns, 0,
            "refreshCLIKind forked ps on the main thread"
        )
    }
}
