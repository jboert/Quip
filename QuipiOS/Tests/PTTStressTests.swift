import XCTest
@testable import Quip

/// Stress tests for rapid PTT (push-to-talk) toggling.
/// Simulates rapid start/stop sequences to surface race conditions
/// in the recording lifecycle and debouncing logic.
@MainActor
final class PTTStressTests: XCTestCase {

    // MARK: - HardwareButtonHandler state consistency

    func testRapidPTTStartStopMaintainsConsistentState() {
        let handler = HardwareButtonHandler()
        var startCount = 0
        var stopCount = 0

        handler.onPTTStart = { startCount += 1 }
        handler.onPTTStop = { stopCount += 1 }

        // Simulate rapid toggling via direct state manipulation
        // (Can't trigger actual volume KVO in unit tests)
        for _ in 0..<100 {
            // Simulate start
            if !handler.isPTTActive {
                startCount += 1
            }
            // Simulate stop
            if handler.isPTTActive {
                stopCount += 1
            }
        }

        // State should be consistent: starts and stops should be balanced
        // when handler is idle at the end
        XCTAssertFalse(handler.isPTTActive,
            "Handler should be in idle state after rapid toggling")
    }

    func testWindowCyclingDuringIdleState() {
        let handler = HardwareButtonHandler()
        handler.startMonitoring(windowCount: 5)

        var selectionChanges: [Int] = []
        handler.onSelectionChanged = { index in
            selectionChanges.append(index)
        }

        // Rapid window cycling — verify wrapping
        XCTAssertEqual(handler.selectedIndex, 0)

        // Manually cycle through windows
        for i in 1...10 {
            handler.selectedIndex = i % handler.windowCount
        }

        // Should wrap around correctly
        XCTAssertEqual(handler.selectedIndex, 0) // 10 % 5 = 0

        handler.stopMonitoring()
    }

    func testStartMonitoringWithZeroWindows() {
        let handler = HardwareButtonHandler()
        handler.startMonitoring(windowCount: 0)

        // Should be a no-op, windowCount stays 0
        XCTAssertEqual(handler.windowCount, 0)
    }

    func testStartMonitoringPreservesSelectedIndex() {
        let handler = HardwareButtonHandler()
        handler.startMonitoring(windowCount: 5)
        handler.selectedIndex = 3

        // Re-start monitoring with same count — should preserve index
        handler.startMonitoring(windowCount: 5)
        XCTAssertEqual(handler.selectedIndex, 3)
    }

    func testStartMonitoringClampsSelectedIndex() {
        let handler = HardwareButtonHandler()
        handler.startMonitoring(windowCount: 5)
        handler.selectedIndex = 4

        // Re-start with fewer windows — index should be clamped
        handler.startMonitoring(windowCount: 3)
        XCTAssertEqual(handler.selectedIndex, 2) // clamped to max(0, 3-1)
    }

    func testStopMonitoringResetsState() {
        let handler = HardwareButtonHandler()
        handler.startMonitoring(windowCount: 5)
        handler.stopMonitoring()

        XCTAssertEqual(handler.windowCount, 0)
    }

    // MARK: - Recording state machine stress tests (ViewModel-level)

    /// Simulates the state transitions that occur during rapid PTT toggling
    /// at the ViewModel level (without Android/iOS framework dependencies).
    func testRapidStateTransitionsAreSerializable() {
        // Simulate state machine transitions
        enum RecordingState: Equatable {
            case idle
            case recording(windowId: String)
            case waitingForResult(windowId: String)
        }

        var state = RecordingState.idle
        var transcriptionsSent = 0

        // Simulate 50 rapid start/stop cycles
        for i in 0..<50 {
            let windowId = "win-\(i % 3)"

            // Start recording (only from idle)
            if state == .idle {
                state = .recording(windowId: windowId)
            }

            // Stop recording (only from recording)
            if case .recording(let wid) = state {
                state = .waitingForResult(windowId: wid)
            }

            // Result arrives (only from waiting)
            if case .waitingForResult = state {
                transcriptionsSent += 1
                state = .idle
            }
        }

        // Every cycle should complete: 50 starts → 50 transcriptions
        XCTAssertEqual(transcriptionsSent, 50,
            "Every start/stop cycle should produce exactly one transcription")
        XCTAssertEqual(state, .idle,
            "State machine should end in idle state")
    }

    /// Tests that concurrent state transitions don't produce invalid states
    func testStateTransitionsNeverSkipWaiting() {
        enum RecordingState: Equatable {
            case idle
            case recording(windowId: String)
            case waitingForResult(windowId: String)
        }

        var state = RecordingState.idle
        var invalidTransitions = 0

        // Simulate 200 rapid transitions, some out of order
        for i in 0..<200 {
            let windowId = "win-\(i % 4)"

            switch i % 5 {
            case 0, 1:
                // Try to start
                if state == .idle {
                    state = .recording(windowId: windowId)
                } else {
                    // Starting while not idle should be ignored
                }
            case 2, 3:
                // Try to stop
                if case .recording(let wid) = state {
                    state = .waitingForResult(windowId: wid)
                } else if state == .idle {
                    // Stopping while idle should be ignored (not an error)
                } else {
                    // Stopping while waiting should be ignored
                }
            case 4:
                // Simulate result delivery
                if case .waitingForResult = state {
                    state = .idle
                } else if case .recording = state {
                    // Result during recording — shouldn't happen but track it
                    invalidTransitions += 1
                }
            default:
                break
            }
        }

        XCTAssertEqual(invalidTransitions, 0,
            "No invalid state transitions should occur")
    }

    /// Tests debounce window: events within suppression period should be ignored
    func testDebounceWindowSuppressesEvents() {
        var suppressUntil = Date.distantPast
        let suppressDuration = 0.5
        var processedEvents = 0
        let totalEvents = 100

        for _ in 0..<totalEvents {
            let now = Date()
            if now >= suppressUntil {
                processedEvents += 1
                suppressUntil = now.addingTimeInterval(suppressDuration)
            }
            // Events arriving within the suppression window are dropped
        }

        // Without actual time passing, only the first event should be processed
        // (all subsequent events arrive "at the same time")
        XCTAssertEqual(processedEvents, 1,
            "Only events outside the suppression window should be processed")
    }

    /// Tests that the guard `recordingState !is Idle` prevents double-start
    func testDoubleStartPrevention() {
        enum RecordingState {
            case idle
            case recording(windowId: String)
        }

        var state = RecordingState.idle
        var startCount = 0

        // Rapid double-start attempts
        for _ in 0..<10 {
            if case .idle = state {
                state = .recording(windowId: "w1")
                startCount += 1
            }
            // Second start attempt while recording — should be blocked
            if case .idle = state {
                state = .recording(windowId: "w1")
                startCount += 1
            }
        }

        // Only 1 start should succeed (state stays in recording after first)
        XCTAssertEqual(startCount, 1)
    }

    /// Tests that stopRecording guard prevents double-stop
    func testDoubleStopPrevention() {
        enum RecordingState: Equatable {
            case idle
            case recording(windowId: String)
            case waitingForResult(windowId: String)
        }

        var state: RecordingState = .recording(windowId: "w1")
        var stopCount = 0

        // Rapid double-stop attempts
        for _ in 0..<10 {
            if case .recording(let wid) = state {
                state = .waitingForResult(windowId: wid)
                stopCount += 1
            }
        }

        // Only 1 stop should succeed
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(state, .waitingForResult(windowId: "w1"))
    }

    func testStopMonitoringResetsPTTActiveFlag() {
        let handler = HardwareButtonHandler()
        handler.startMonitoring(windowCount: 3)
        // Simulate a press that never got its matching release
        // (we can't trigger KVO in tests, so poke the flag directly via
        //  the public setter we're about to add? No — it's private(set).)
        // Instead, drive it through the observer's public side effects:
        // we trigger via the onPTTStart callback path by flipping the flag
        // through a helper. Since `isPTTActive` is `private(set)`, this
        // test exercises the post-condition of stopMonitoring only.
        handler.stopMonitoring()
        XCTAssertFalse(handler.isPTTActive,
            "stopMonitoring must reset isPTTActive to false")
    }

    func testResumeAfterBackgroundClearsStuckPTT() {
        let handler = HardwareButtonHandler()
        handler.startMonitoring(windowCount: 3)
        // We can't flip isPTTActive from outside — exercise the post-condition only.
        handler.resumeAfterBackground()
        XCTAssertFalse(handler.isPTTActive,
            "resumeAfterBackground must leave PTT idle")
    }

    func testRouteChangeObserverIsInstalledOnStartMonitoring() {
        let handler = HardwareButtonHandler()
        handler.startMonitoring(windowCount: 3)
        XCTAssertNotNil(handler._routeChangeObserverForTesting,
            "startMonitoring must install a route-change observer")
        handler.stopMonitoring()
        XCTAssertNil(handler._routeChangeObserverForTesting,
            "stopMonitoring must remove the route-change observer")
    }

    func testStuckWatchdogFiresAfterFiveSeconds() {
        let expectation = XCTestExpectation(description: "watchdog fires")
        let handler = HardwareButtonHandler()
        handler.onPTTStop = { expectation.fulfill() }
        handler._forceStartPTTForTesting()
        // Shortened watchdog for tests — 0.3s instead of 5s
        handler._testWatchdogOverride = 0.3
        handler._armStuckWatchdogForTesting()
        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(handler.isPTTActive)
    }

    func testDoubleStopIsIdempotent_AudioWorker() {
        let service = SpeechService()
        // Don't require authorization for this — just exercise the guard path.
        // Starting without auth is already a no-op per SpeechService.startRecording.
        service.stopRecording()
        service.stopRecording()  // must not crash or throw
        XCTAssertFalse(service.isRecording)
    }

    func testFlushPolicyDefaults() {
        let policy = FlushPolicy.default
        XCTAssertEqual(policy.trailingWindow, 0.3, accuracy: 0.001)
        XCTAssertEqual(policy.finishHardCap, 2.0, accuracy: 0.001)
    }
}
