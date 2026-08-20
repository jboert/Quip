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

    /// The poll loop must publish its snapshot so main-thread callers have
    /// something to read. Without this, refreshCLIKind has no choice but to
    /// fork.
    func test_pollLoop_publishesSnapshotToCache() {
        XCTAssertFalse(
            detector.hasFreshSnapshot(maxAge: 5.0),
            "cache should start empty"
        )

        detector.trackWindow("w1", shellPid: ProcessInfo.processInfo.processIdentifier, tty: nil)
        detector.startMonitoring()

        let published = expectation(description: "poll loop published a snapshot")
        // Poll interval is 0.25s; give it several cycles of headroom.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if self.detector.hasFreshSnapshot(maxAge: 5.0) { published.fulfill() }
        }
        wait(for: [published], timeout: 5.0)
    }

    /// A watched child exiting must not trigger a ps fork. This was the
    /// dominant hang: one system-wide `ps -ax` per child exit, on main,
    /// serialized behind every other exit in the burst.
    func test_processExit_doesNotSpawnProcessOnMainThread() {
        detector.trackWindow("w1", shellPid: 4242, tty: nil)
        TerminalStateDetector.resetMainThreadProcessSpawnCount()

        detector.handleProcessExit(windowId: "w1", pid: 4242)

        XCTAssertEqual(
            TerminalStateDetector.mainThreadProcessSpawns, 0,
            "child-process exit forked ps on the main thread"
        )
    }

    /// A burst of exits — the real-world shape during a Claude session — must
    /// stay at zero forks, not merely "fewer".
    func test_processExitBurst_doesNotSpawnProcessOnMainThread() {
        detector.trackWindow("w1", shellPid: 4242, tty: nil)
        TerminalStateDetector.resetMainThreadProcessSpawnCount()

        for pid in pid_t(5000)..<pid_t(5100) {
            detector.handleProcessExit(windowId: "w1", pid: pid)
        }

        XCTAssertEqual(
            TerminalStateDetector.mainThreadProcessSpawns, 0,
            "exit burst forked ps on the main thread"
        )
    }

    /// Even with a stale-PID window that has an iTerm2 TTY — the case that
    /// makes detectState fall through to shellPidForTTY — the on-main path
    /// must not fork.
    func test_refreshCLIKind_withTTY_doesNotSpawnProcessOnMainThread() {
        detector.trackWindow("w1", shellPid: 999_999, tty: "ttys999")
        TerminalStateDetector.resetMainThreadProcessSpawnCount()

        _ = detector.refreshCLIKind(for: "w1")

        XCTAssertEqual(
            TerminalStateDetector.mainThreadProcessSpawns, 0,
            "refreshCLIKind fell through to the shellPidForTTY fork on main"
        )
    }
}
