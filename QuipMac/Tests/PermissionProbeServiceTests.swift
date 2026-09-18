import XCTest
@testable import Quip

/// Regression cover for Quip_2026-07-30-091540.hang: a 6.3-second freeze with
/// every sample inside AEDeterminePermissionToAutomateTarget's semaphore wait,
/// reached from a 5-second timer on the main thread.
final class PermissionProbeServiceTests: XCTestCase {

    /// The three TCC calls must not execute on the main thread.
    /// AEDeterminePermissionToAutomateTarget blocks on IPC and cannot be
    /// allowed to block the UI.
    func test_refresh_runsProbesOffMainThread() {
        let flag = MainThreadFlag()
        let probes = PermissionProbeService.Probes(
            accessibility: { flag.noteIfMain(); return true },
            appleEvents: { flag.noteIfMain(); return true },
            screenRecording: { flag.noteIfMain(); return true }
        )
        let service = PermissionProbeService(probes: probes)

        let done = expectation(description: "refresh completed")
        service.refresh { _ in done.fulfill() }
        wait(for: [done], timeout: 5.0)

        XCTAssertFalse(flag.ranOnMain, "TCC probes ran on the main thread")
    }

    /// The completion must land on main — callers mutate @Observable
    /// MainActor state (permissionsStore) with it.
    func test_refresh_deliversCompletionOnMainThread() {
        let service = PermissionProbeService(probes: .init(
            accessibility: { true }, appleEvents: { true }, screenRecording: { true }
        ))

        let done = expectation(description: "completion on main")
        service.refresh { _ in
            XCTAssertTrue(Thread.isMainThread, "completion did not land on main")
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)
    }

    /// A slow Apple Events round-trip must not let the 5s app timer and the
    /// Settings tab stack probes on top of each other.
    func test_refresh_coalescesConcurrentRequests() {
        let gate = DispatchSemaphore(value: 0)
        let counter = ProbeCounter()
        let service = PermissionProbeService(probes: .init(
            accessibility: { gate.wait(); counter.increment(); return true },
            appleEvents: { true },
            screenRecording: { true }
        ))

        let done = expectation(description: "all completions fired")
        done.expectedFulfillmentCount = 5
        for _ in 0..<5 { service.refresh { _ in done.fulfill() } }

        gate.signal() // release the single in-flight probe
        wait(for: [done], timeout: 5.0)

        XCTAssertEqual(counter.value, 1, "concurrent refreshes were not coalesced")
    }

    /// Callers that cannot wait (SwiftUI view bodies) read the last completed
    /// snapshot instead of forcing a probe.
    func test_lastSnapshot_isNilBeforeFirstRefreshThenPopulated() {
        let service = PermissionProbeService(probes: .init(
            accessibility: { true }, appleEvents: { false }, screenRecording: { true }
        ))
        XCTAssertNil(service.lastSnapshot)

        let done = expectation(description: "refresh completed")
        service.refresh { _ in done.fulfill() }
        wait(for: [done], timeout: 5.0)

        XCTAssertEqual(service.lastSnapshot?.appleEvents, false)
    }
}

/// Lock-guarded flag — the probe closures run on a background queue.
private final class MainThreadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false
    func noteIfMain() {
        guard Thread.isMainThread else { return }
        lock.lock(); flagged = true; lock.unlock()
    }
    var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return flagged }
}

/// Lock-guarded counter — same reason.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
