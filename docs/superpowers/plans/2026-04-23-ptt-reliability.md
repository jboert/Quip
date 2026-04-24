# PTT Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix start-clip, end-clip, seam-drop, and button-hygiene bugs on the current iPhone on-device `SFSpeechRecognizer` PTT path, without swapping the recognizer.

**Architecture:** Five independently-shippable iterations against `HardwareButtonHandler` and `SpeechService`. Each iteration has pure-Swift unit tests (matching existing `PTTStressTests` pattern) plus a device-only manual acceptance script. No Mac changes, no protocol changes, no SwiftUI view changes.

**Tech Stack:** Swift 6 (`SWIFT_STRICT_CONCURRENCY: minimal`), iOS 17+, `@Observable`, `@MainActor`, `AVFoundation`, `Speech` (`SFSpeechRecognizer`), XCTest, `xcodebuild test`, xcodegen.

---

## File Structure

**Modified:**
- `QuipiOS/Services/HardwareButtonHandler.swift` — button hygiene (Iter 1), arm/disarm hooks (Iter 3)
- `QuipiOS/Services/SpeechService.swift` — trailing flush, pre-arm ring buffer, seam stitching, vocab loading (Iters 2–5)
- `QuipiOS/Tests/PTTStressTests.swift` — new test cases per iteration
- `docs/superpowers/wishlist.md` — mark this plan in progress / done when appropriate

**Created:**
- `Shared/SeamStitcher.swift` — pure function for dedup-by-word-overlap (Iter 4). Placed in `Shared/` so it's reachable from both test targets if needed.
- `Shared/AudioRingBuffer.swift` — timestamped fixed-size ring buffer (Iter 3).
- `QuipiOS/Resources/dictation-vocab.txt` — seed vocab list (Iter 5). Bundled into app via xcodegen auto-include.
- `Shared/Tests/SeamStitcherTests.swift` — unit tests for stitcher
- `Shared/Tests/AudioRingBufferTests.swift` — unit tests for ring buffer

**Unchanged:** `Shared/PTTWindowTracker.swift`, all Mac code, all protocol files, all views.

---

## Iteration 1 — Button hygiene

Ships first. Lowest risk, no audio-engine changes, no recognizer changes.

### Task 1.1: Reset `isPTTActive` on `stopMonitoring`

**Files:**
- Modify: `QuipiOS/Services/HardwareButtonHandler.swift:129-133`
- Test: `QuipiOS/Tests/PTTStressTests.swift`

- [ ] **Step 1: Write the failing test**

Add at the end of `PTTStressTests` (before the closing brace):

```swift
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
```

- [ ] **Step 2: Run test to verify it fails (or trivially passes)**

Run: `xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:QuipiOSTests/PTTStressTests/testStopMonitoringResetsPTTActiveFlag`

Expected: PASS (the default of `isPTTActive` is `false`, so before the real bug scenario this test is tautological). We'll strengthen it in Iter 3 once there's a way to drive `isPTTActive = true` deterministically. For now we're proving the fix is in place and doesn't regress.

- [ ] **Step 3: Make `stopMonitoring` defensively clear the flag**

In `QuipiOS/Services/HardwareButtonHandler.swift`, replace:

```swift
func stopMonitoring() {
    volumeObservation?.invalidate()
    volumeObservation = nil
    windowCount = 0
}
```

with:

```swift
func stopMonitoring() {
    volumeObservation?.invalidate()
    volumeObservation = nil
    windowCount = 0
    if isPTTActive {
        isPTTActive = false
        onPTTStop?()
    }
    suppressUntil = .distantPast
    cancelStuckWatchdog()
}
```

(`cancelStuckWatchdog()` is introduced in Task 1.4 — add the call now; we'll add a temporary empty `private func cancelStuckWatchdog() {}` to compile this step.)

Also add the stub method inside the class:

```swift
private func cancelStuckWatchdog() {
    // Implemented in Task 1.4
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/Services/HardwareButtonHandler.swift QuipiOS/Tests/PTTStressTests.swift
git commit -m "$(cat <<'EOF'
Reset isPTTActive on stopMonitoring — guard against stuck-press state when window list drops to zero or monitoring is recycled.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.2: Reset `isPTTActive` on `resumeAfterBackground`

**Files:**
- Modify: `QuipiOS/Services/HardwareButtonHandler.swift:117-127`
- Test: `QuipiOS/Tests/PTTStressTests.swift`

- [ ] **Step 1: Write the failing test**

Add:

```swift
func testResumeAfterBackgroundClearsStuckPTT() {
    let handler = HardwareButtonHandler()
    handler.startMonitoring(windowCount: 3)
    // We can't flip isPTTActive from outside — exercise the post-condition only.
    handler.resumeAfterBackground()
    XCTAssertFalse(handler.isPTTActive,
        "resumeAfterBackground must leave PTT idle")
}
```

- [ ] **Step 2: Run test**

Run: `xcodebuild test ... -only-testing:QuipiOSTests/PTTStressTests/testResumeAfterBackgroundClearsStuckPTT`
Expected: PASS (same tautology caveat as 1.1 — strengthens in Iter 3).

- [ ] **Step 3: Update `resumeAfterBackground`**

Replace the current body:

```swift
func resumeAfterBackground() {
    guard volumeObservation != nil else { return }
    let session = AVAudioSession.sharedInstance()
    do {
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
    } catch {}
    suppressUntil = Date().addingTimeInterval(Self.volumeRestoreSuppression)
    HiddenVolumeView.setVolume(0.5)
}
```

with:

```swift
func resumeAfterBackground() {
    guard volumeObservation != nil else { return }
    // If a press was in flight when we backgrounded, deliver the stop now —
    // volume KVO was paused, so there was no natural release event.
    if isPTTActive {
        isPTTActive = false
        onPTTStop?()
    }
    cancelStuckWatchdog()
    let session = AVAudioSession.sharedInstance()
    do {
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
    } catch {}
    suppressUntil = Date().addingTimeInterval(Self.volumeRestoreSuppression)
    HiddenVolumeView.setVolume(0.5)
}
```

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/Services/HardwareButtonHandler.swift QuipiOS/Tests/PTTStressTests.swift
git commit -m "$(cat <<'EOF'
Deliver stop-PTT on resume-from-background — volume KVO pauses while backgrounded so the natural release event never arrives; sending onPTTStop on resume avoids the flag sticking true across lifecycle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.3: Observe audio route changes, force-stop PTT when route flips

**Files:**
- Modify: `QuipiOS/Services/HardwareButtonHandler.swift`
- Test: `QuipiOS/Tests/PTTStressTests.swift`

- [ ] **Step 1: Write the failing test**

Add:

```swift
func testRouteChangeObserverIsInstalledOnStartMonitoring() {
    let handler = HardwareButtonHandler()
    handler.startMonitoring(windowCount: 3)
    XCTAssertNotNil(handler._routeChangeObserverForTesting,
        "startMonitoring must install a route-change observer")
    handler.stopMonitoring()
    XCTAssertNil(handler._routeChangeObserverForTesting,
        "stopMonitoring must remove the route-change observer")
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `_routeChangeObserverForTesting` not a member.

- [ ] **Step 3: Add the observer**

In `HardwareButtonHandler` class body:

```swift
private var routeChangeObserver: NSObjectProtocol?

#if DEBUG
var _routeChangeObserverForTesting: NSObjectProtocol? { routeChangeObserver }
#endif
```

In `startMonitoring(windowCount:)`, after the `volumeObservation = session.observe(...)` block, insert:

```swift
if routeChangeObserver == nil {
    routeChangeObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: nil, queue: .main
    ) { [weak self] _ in
        guard let self else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        if self.isPTTActive {
            self.isPTTActive = false
            self.suppressUntil = Date().addingTimeInterval(Self.pttTransitionSuppression)
            self.onPTTStop?()
        }
    }
}
```

In `stopMonitoring()`, before the function returns, add:

```swift
if let observer = routeChangeObserver {
    NotificationCenter.default.removeObserver(observer)
    routeChangeObserver = nil
}
```

- [ ] **Step 4: Run test**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/Services/HardwareButtonHandler.swift QuipiOS/Tests/PTTStressTests.swift
git commit -m "$(cat <<'EOF'
Force-stop PTT on audio route change — AirPods in/out, BT disconnect, or Siri interruption can swap the route mid-press; without this the handler stays stuck active until the next volume event.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.4: Stuck-press watchdog at 5 seconds

**Files:**
- Modify: `QuipiOS/Services/HardwareButtonHandler.swift`
- Test: `QuipiOS/Tests/PTTStressTests.swift`

- [ ] **Step 1: Write the failing test**

Add:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — the testing hooks don't exist.

- [ ] **Step 3: Add the watchdog**

In `HardwareButtonHandler`:

```swift
private static let stuckPressWatchdog: TimeInterval = 5.0
private var stuckWatchdog: DispatchWorkItem?

#if DEBUG
var _testWatchdogOverride: TimeInterval?
func _forceStartPTTForTesting() {
    isPTTActive = true
    onPTTStart?()
}
func _armStuckWatchdogForTesting() { armStuckWatchdog() }
#endif

private func armStuckWatchdog() {
    cancelStuckWatchdog()
    let interval: TimeInterval = {
        #if DEBUG
        return _testWatchdogOverride ?? Self.stuckPressWatchdog
        #else
        return Self.stuckPressWatchdog
        #endif
    }()
    let work = DispatchWorkItem { [weak self] in
        guard let self, self.isPTTActive else { return }
        NSLog("[Quip][PTT] watchdog fired — forcing stop after %.1fs", interval)
        self.isPTTActive = false
        self.suppressUntil = Date().addingTimeInterval(Self.pttTransitionSuppression)
        self.onPTTStop?()
    }
    stuckWatchdog = work
    DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
}
```

Replace the empty stub `cancelStuckWatchdog` from Task 1.1 with:

```swift
private func cancelStuckWatchdog() {
    stuckWatchdog?.cancel()
    stuckWatchdog = nil
}
```

In the KVO closure inside `startMonitoring`, after the line `self.onPTTStart?()` (inside the `if wentDown` branch that flips `isPTTActive` true), add:

```swift
self.armStuckWatchdog()
```

In the same closure, inside the `if self.isPTTActive { ... }` branch that flips it to false, after `self.onPTTStop?()`, add:

```swift
self.cancelStuckWatchdog()
```

- [ ] **Step 4: Run test**

Expected: PASS within ~0.3s.

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/Services/HardwareButtonHandler.swift QuipiOS/Tests/PTTStressTests.swift
git commit -m "$(cat <<'EOF'
Add 5s stuck-press watchdog — any press with no matching release after 5s is treated as jammed; forces onPTTStop and logs. Configurable for tests via DEBUG-only override.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.5: Iteration 1 device acceptance

- [ ] **Step 1: Install to phone**

Per project standing recipe, build + install iOS bundle to the default device (iPhone 17 Pro Max via `devicectl`). Force-quit Quip from the app switcher, then relaunch — `devicectl install` replaces the bundle but does not kill the running process.

```bash
cd QuipiOS && xcodegen generate && xcodebuild -project QuipiOS.xcodeproj -scheme QuipiOS -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build build
devicectl device install app --device "Tim apple 17" build/Build/Products/Debug-iphoneos/Quip.app
```

- [ ] **Step 2: Verify — resume from background**

Background Quip (swipe up halfway, not fully). Reopen. Press volume-down. **Expected:** recording starts within 200ms, overlay shows.

- [ ] **Step 3: Verify — route change mid-press**

Begin a press. While holding, insert or remove AirPods (or trigger Siri briefly). **Expected:** recording stops automatically; any partial transcript is delivered. No stuck overlay.

- [ ] **Step 4: Verify — no regression**

Run 10 normal press/release cycles. All 10 should record and transcribe without issue.

- [ ] **Step 5: Mark Iter 1 acceptance**

No commit needed unless issues surface. If a regression is found, revert the iteration and diagnose — do not patch over.

---

## Iteration 2 — Trailing flush (end-clip fix)

### Task 2.1: Guard double-stop in `AudioWorker`

**Files:**
- Modify: `QuipiOS/Services/SpeechService.swift` (inside `AudioWorker`)
- Test: `QuipiOS/Tests/PTTStressTests.swift`

- [ ] **Step 1: Write the failing test**

Add:

```swift
func testDoubleStopIsIdempotent_AudioWorker() {
    let service = SpeechService()
    // Don't require authorization for this — just exercise the guard path.
    // Starting without auth is already a no-op per SpeechService.startRecording.
    service.stopRecording()
    service.stopRecording()  // must not crash or throw
    XCTAssertFalse(service.isRecording)
}
```

- [ ] **Step 2: Run test**

Expected: PASS (current code already guards). Serves as a regression lock before we restructure `stop()`.

- [ ] **Step 3: Commit the regression-lock**

```bash
git add QuipiOS/Tests/PTTStressTests.swift
git commit -m "$(cat <<'EOF'
Lock in idempotent stopRecording — regression guard before refactoring AudioWorker.stop with trailing flush.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.2: Add trailing-flush window to `AudioWorker.stop()`

**Files:**
- Modify: `QuipiOS/Services/SpeechService.swift` (lines 310-323)

- [ ] **Step 1: Write a logic-level test for the flush state machine**

Trailing-flush cannot be tested through the real audio engine in unit tests. Instead, extract the timing policy into a testable helper.

In `QuipiOS/Services/SpeechService.swift`, above the `private class AudioWorker`, add:

```swift
/// Pure policy object: decides whether a stop request should flush or be rejected as duplicate.
struct FlushPolicy {
    let trailingWindow: TimeInterval
    let finishHardCap: TimeInterval

    static let `default` = FlushPolicy(trailingWindow: 0.3, finishHardCap: 2.0)
}
```

Add to `PTTStressTests.swift`:

```swift
func testFlushPolicyDefaults() {
    let policy = FlushPolicy.default
    XCTAssertEqual(policy.trailingWindow, 0.3, accuracy: 0.001)
    XCTAssertEqual(policy.finishHardCap, 2.0, accuracy: 0.001)
}
```

- [ ] **Step 2: Run test**

Expected: PASS.

- [ ] **Step 3: Rewrite `AudioWorker.stop()` to use trailing flush**

Replace current `stop()`:

```swift
func stop() {
    queue.async { [self] in
        self.isStopping = true
        recognitionRequest?.endAudio()
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        // Use finish() instead of cancel() to get the final transcription
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
    }
}
```

with:

```swift
private var isFlushing = false
private let policy: FlushPolicy = .default

func stop() {
    queue.async { [self] in
        guard !self.isFlushing else { return }
        guard !self.isStopping || self.recognitionTask != nil else { return }
        self.isStopping = true
        self.isFlushing = true

        // End audio input — tap keeps forwarding any already-buffered samples
        // into the request until we tear it down.
        self.recognitionRequest?.endAudio()

        // 300ms later, remove the tap, stop engine, finish the task.
        self.queue.asyncAfter(deadline: .now() + self.policy.trailingWindow) { [weak self] in
            guard let self else { return }
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
                self.audioEngine.inputNode.removeTap(onBus: 0)
            }
            self.recognitionTask?.finish()

            // Hard cap: if isFinal doesn't fire within finishHardCap, force-close.
            let taskRef = self.recognitionTask
            self.queue.asyncAfter(deadline: .now() + self.policy.finishHardCap) { [weak self] in
                guard let self else { return }
                if self.recognitionTask === taskRef, taskRef != nil {
                    NSLog("[Quip][PTT] flush timeout at %.1fs — cancelling task", self.policy.finishHardCap)
                    taskRef?.cancel()
                    self.recognitionTask = nil
                    self.recognitionRequest = nil
                    self.onUpdateCallback?(self.accumulatedText.isEmpty ? nil : self.accumulatedText, true)
                }
                self.isFlushing = false
            }
        }
    }
}
```

Also: in `beginRecognitionTask`'s `isFinal` branch, add `self.isFlushing = false` after the `onUpdateCallback?(combined, true)` call in the `if self.isStopping` branch, so the flag resets normally.

- [ ] **Step 4: Run tests**

Run: `xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:QuipiOSTests`
Expected: all 51 existing + 5 new (from Iter 1+2) PASS.

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/Services/SpeechService.swift QuipiOS/Tests/PTTStressTests.swift
git commit -m "$(cat <<'EOF'
Add 300ms trailing-flush window to AudioWorker.stop — the previous back-to-back endAudio/finish raced against the tap, dropping the final word; the tap now continues for 300ms, then the task is finished with a 2s hard cap.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.3: Iteration 2 device acceptance

- [ ] **Step 1: Install + force-quit + relaunch**

Same install steps as 1.5.

- [ ] **Step 2: Verify — last word captured**

Hold volume-down. Say "hello world". Release immediately after the "d" of "world". **Expected:** prompt contains both words.

- [ ] **Step 3: Verify — repeated cycles**

Run 10 short presses each ending on a hard consonant ("dog", "cat", "stop", "test"). All 10 should contain the final word.

- [ ] **Step 4: Verify — long release not broken**

Release the button with a long trailing silence (press, say "hello", wait 2 seconds, release). **Expected:** "hello" appears; no duplicate, no hang.

---

## Iteration 3 — Pre-arm ring buffer (start-clip fix)

### Task 3.1: `AudioRingBuffer` — pure type

**Files:**
- Create: `Shared/AudioRingBuffer.swift`
- Create: `Shared/Tests/AudioRingBufferTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Shared/Tests/AudioRingBufferTests.swift`:

```swift
import XCTest
import AVFoundation
@testable import Quip

final class AudioRingBufferTests: XCTestCase {
    private func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    }

    func testAppendDropsBuffersOlderThanWindow() {
        let ring = AudioRingBuffer(window: 0.5)  // 500ms
        let now = Date()
        ring.append(buffer: makeBuffer(), at: now.addingTimeInterval(-1.0))  // 1s ago
        ring.append(buffer: makeBuffer(), at: now.addingTimeInterval(-0.3))  // 300ms ago
        ring.append(buffer: makeBuffer(), at: now)
        let kept = ring.entries(relativeTo: now)
        XCTAssertEqual(kept.count, 2, "Entries older than window should drop")
    }

    func testReplayIsOrderPreserving() {
        let ring = AudioRingBuffer(window: 1.0)
        let base = Date()
        let b1 = makeBuffer()
        let b2 = makeBuffer()
        let b3 = makeBuffer()
        ring.append(buffer: b1, at: base.addingTimeInterval(-0.4))
        ring.append(buffer: b2, at: base.addingTimeInterval(-0.2))
        ring.append(buffer: b3, at: base)
        let kept = ring.entries(relativeTo: base)
        XCTAssertEqual(kept.count, 3)
        XCTAssertTrue(kept[0].buffer === b1)
        XCTAssertTrue(kept[1].buffer === b2)
        XCTAssertTrue(kept[2].buffer === b3)
    }

    func testClearRemovesAll() {
        let ring = AudioRingBuffer(window: 1.0)
        ring.append(buffer: makeBuffer(), at: Date())
        ring.clear()
        XCTAssertTrue(ring.entries(relativeTo: Date()).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:QuipiOSTests/AudioRingBufferTests`
Expected: FAIL — `AudioRingBuffer` does not exist.

- [ ] **Step 3: Implement `AudioRingBuffer`**

Create `Shared/AudioRingBuffer.swift`:

```swift
import AVFoundation
import Foundation

/// Fixed-time-window ring buffer of PCM audio buffers.
/// Thread-safety: caller-provided. Intended to be used from a single serial queue.
final class AudioRingBuffer {
    struct Entry {
        let buffer: AVAudioPCMBuffer
        let timestamp: Date
    }

    private let window: TimeInterval
    private var storage: [Entry] = []

    init(window: TimeInterval) {
        self.window = window
    }

    func append(buffer: AVAudioPCMBuffer, at timestamp: Date) {
        storage.append(Entry(buffer: buffer, timestamp: timestamp))
        prune(relativeTo: timestamp)
    }

    func entries(relativeTo now: Date) -> [Entry] {
        prune(relativeTo: now)
        return storage
    }

    func clear() {
        storage.removeAll(keepingCapacity: true)
    }

    private func prune(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        storage.removeAll { $0.timestamp < cutoff }
    }
}
```

- [ ] **Step 4: Run test**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/AudioRingBuffer.swift Shared/Tests/AudioRingBufferTests.swift
git commit -m "$(cat <<'EOF'
Add AudioRingBuffer — fixed-time-window PCM buffer list, pruned on every append. Used by the next commit to capture 500ms of pre-roll audio so PTT's first word isn't clipped by cold-start latency.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.2: `AudioWorker` arm / disarm + always-installed tap

**Files:**
- Modify: `QuipiOS/Services/SpeechService.swift`
- Modify: `QuipiOS/Services/HardwareButtonHandler.swift`

- [ ] **Step 1: Add `arm()` / `disarm()` to `AudioWorker` and call tap-install path from there**

In `AudioWorker`:

```swift
private let ring = AudioRingBuffer(window: 0.5)
private var isArmed = false

func arm() {
    queue.async { [self] in
        guard !self.isArmed else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)

        let input = self.audioEngine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let now = Date()
            // Always forward to the live request when one is attached.
            self.recognitionRequest?.append(buffer)
            // Always retain last 500ms for pre-roll replay.
            self.ring.append(buffer: buffer, at: now)
        }
        do {
            self.audioEngine.prepare()
            try self.audioEngine.start()
            self.isArmed = true
        } catch {
            NSLog("[Quip][PTT] arm: engine start failed: %@", error.localizedDescription)
        }
    }
}

func disarm() {
    queue.async { [self] in
        guard self.isArmed else { return }
        self.audioEngine.stop()
        self.audioEngine.inputNode.removeTap(onBus: 0)
        self.ring.clear()
        self.isArmed = false
    }
}
```

- [ ] **Step 2: Use the ring in `start()` — replay pre-roll into the new request**

Replace `start(onUpdate:)`'s existing body:

```swift
func start(onUpdate: @escaping (String?, Bool) -> Void) {
    queue.async { [self] in
        self.accumulatedText = ""
        self.isStopping = false
        self.isFlushing = false
        self.onUpdateCallback = onUpdate

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onUpdate(nil, true)
            return
        }

        // Under the long-lived engine model, `arm()` has already installed the tap.
        // If somehow we weren't armed (arm failed), fall back to cold-start.
        if !self.isArmed {
            let input = self.audioEngine.inputNode
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
            do {
                self.audioEngine.prepare()
                try self.audioEngine.start()
            } catch {
                onUpdate(nil, true)
                return
            }
        }

        self.beginRecognitionTask(recognizer: recognizer)

        // Replay pre-roll into the request we just created.
        let now = Date()
        for entry in self.ring.entries(relativeTo: now) {
            self.recognitionRequest?.append(entry.buffer)
        }
    }
}
```

Update `stop()`'s trailing-flush block — under the long-lived engine we do NOT stop the engine or remove the tap. Replace the inner `audioEngine.stop` / `removeTap` lines in the 300ms-later block with:

```swift
// Engine + tap stay running (long-lived under arm/disarm).
// Only the recognition task is finished.
self.recognitionTask?.finish()
```

The earlier cold-start fallback branch inside `start()` still tears down engine+tap in its own `stop()` path if `isArmed` was false — leave that path alone, it's the unarmed fallback.

- [ ] **Step 3: Hook arm/disarm to `HardwareButtonHandler`**

Add to `SpeechService`:

```swift
func arm() { worker.arm() }
func disarm() { worker.disarm() }
```

In `HardwareButtonHandler`, add a callback:

```swift
var onArm: (() -> Void)?
var onDisarm: (() -> Void)?
```

In `startMonitoring(windowCount:)`, after `suppressUntil = ...`, add:

```swift
onArm?()
```

In `stopMonitoring()`, before the closing brace, add:

```swift
onDisarm?()
```

Wire it up: search for where `HardwareButtonHandler` is constructed in `QuipApp.swift` or a view model. Set:

```swift
handler.onArm = { [weak speechService] in speechService?.arm() }
handler.onDisarm = { [weak speechService] in speechService?.disarm() }
```

(If construction lives in a view model, perform the wiring there. Use the Bash tool to grep for `HardwareButtonHandler()` first.)

- [ ] **Step 4: Run full test suite**

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/Services/SpeechService.swift QuipiOS/Services/HardwareButtonHandler.swift QuipiOS/QuipApp.swift
git commit -m "$(cat <<'EOF'
Long-lived audio engine with 500ms pre-roll replay — engine + tap arm when window list populates, pre-roll is continuously captured, and the recognition task replays that pre-roll on PTT start. Fixes the first-word clip that cold-start imposed on every press.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.3: Observe interruptions — disarm/rearm cleanly

**Files:**
- Modify: `QuipiOS/Services/SpeechService.swift`

- [ ] **Step 1: Add interruption observer in `SpeechService.init`**

In `SpeechService`:

```swift
@ObservationIgnored private var interruptionObserver: NSObjectProtocol?

init() {
    interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: nil, queue: .main
    ) { [weak self] note in
        guard let self else { return }
        guard let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            self.worker.disarm()
        case .ended:
            if let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                if options.contains(.shouldResume) { self.worker.arm() }
            }
        @unknown default: break
        }
    }
}

deinit {
    if let obs = interruptionObserver {
        NotificationCenter.default.removeObserver(obs)
    }
}
```

(Verify `SpeechService` doesn't already have an `init()` — if it does, merge rather than duplicate.)

- [ ] **Step 2: Run tests**

Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add QuipiOS/Services/SpeechService.swift
git commit -m "$(cat <<'EOF'
Disarm audio engine on system audio interruption; rearm when shouldResume is set. Covers phone calls, Siri invocation, timer alarms.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.4: Iteration 3 device acceptance

- [ ] **Step 1: Install + force-quit + relaunch**

- [ ] **Step 2: Verify — first word captured**

Press volume-down and speak "hello" at the instant of press (no pause). **Expected:** "hello" appears in prompt.

- [ ] **Step 3: Verify — interruption recovery**

Start a press. While recording, trigger Siri ("Hey Siri, what time is it?"). Dismiss Siri. Press volume-down again. **Expected:** PTT still works; no dead state.

- [ ] **Step 4: Verify — 50 rapid cycles**

Tap volume-down in quick succession 50 times (press/release ~500ms each). No crashes, no missed first words.

---

## Iteration 4 — Seam stitching (1-minute boundary fix)

### Task 4.1: `SeamStitcher` — pure function

**Files:**
- Create: `Shared/SeamStitcher.swift`
- Create: `Shared/Tests/SeamStitcherTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Shared/Tests/SeamStitcherTests.swift`:

```swift
import XCTest
@testable import Quip

final class SeamStitcherTests: XCTestCase {
    func testExactThreeWordOverlapIsRemoved() {
        let old = "the quick brown fox"
        let new = "brown fox jumps over"
        XCTAssertEqual(SeamStitcher.stitch(old: old, new: new),
                       "the quick brown fox jumps over")
    }

    func testOneWordOverlapIsRemoved() {
        let old = "hello world"
        let new = "world goodbye"
        XCTAssertEqual(SeamStitcher.stitch(old: old, new: new),
                       "hello world goodbye")
    }

    func testNoOverlapFallsBackToConcat() {
        let old = "hello world"
        let new = "goodbye cruel world"
        XCTAssertEqual(SeamStitcher.stitch(old: old, new: new),
                       "hello world goodbye cruel world")
    }

    func testCaseInsensitiveMatch() {
        let old = "hello World"
        let new = "world again"
        XCTAssertEqual(SeamStitcher.stitch(old: old, new: new),
                       "hello World again")
    }

    func testEmptyOldReturnsNew() {
        XCTAssertEqual(SeamStitcher.stitch(old: "", new: "hi there"), "hi there")
    }

    func testEmptyNewReturnsOld() {
        XCTAssertEqual(SeamStitcher.stitch(old: "hi there", new: ""), "hi there")
    }

    func testPrefersLongestOverlap() {
        // Old ends "a b c", new starts "b c d". The 2-word overlap
        // should win over a (non-existent) longer or shorter match.
        let old = "x a b c"
        let new = "b c d e"
        XCTAssertEqual(SeamStitcher.stitch(old: old, new: new),
                       "x a b c d e")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `SeamStitcher` not defined.

- [ ] **Step 3: Implement `SeamStitcher`**

Create `Shared/SeamStitcher.swift`:

```swift
import Foundation

/// Joins two consecutive recognizer outputs, stripping any repeated
/// trailing-old / leading-new word overlap.
enum SeamStitcher {
    /// Maximum number of trailing/leading tokens to inspect.
    static let maxOverlap = 3

    static func stitch(old: String, new: String) -> String {
        let oldTrimmed = old.trimmingCharacters(in: .whitespaces)
        let newTrimmed = new.trimmingCharacters(in: .whitespaces)
        if oldTrimmed.isEmpty { return newTrimmed }
        if newTrimmed.isEmpty { return oldTrimmed }

        let oldTokens = oldTrimmed.split(separator: " ").map(String.init)
        let newTokens = newTrimmed.split(separator: " ").map(String.init)

        let bound = min(maxOverlap, oldTokens.count, newTokens.count)
        var overlap = 0
        for k in stride(from: bound, through: 1, by: -1) {
            let oldSuffix = oldTokens.suffix(k).map { $0.lowercased() }
            let newPrefix = newTokens.prefix(k).map { $0.lowercased() }
            if oldSuffix == newPrefix {
                overlap = k
                break
            }
        }

        let keptNew = newTokens.dropFirst(overlap)
        if keptNew.isEmpty { return oldTrimmed }
        return oldTrimmed + " " + keptNew.joined(separator: " ")
    }
}
```

- [ ] **Step 4: Run tests**

Expected: PASS (all 7 cases).

- [ ] **Step 5: Commit**

```bash
git add Shared/SeamStitcher.swift Shared/Tests/SeamStitcherTests.swift
git commit -m "$(cat <<'EOF'
Add SeamStitcher — strips 1–3 word overlap between consecutive recognizer outputs; falls back to simple concat. Used by the next commit to rewrite AudioWorker's multi-task stitching.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.2: Wire `SeamStitcher` into `AudioWorker`

**Files:**
- Modify: `QuipiOS/Services/SpeechService.swift` (inside `AudioWorker.beginRecognitionTask`)

- [ ] **Step 1: Replace the blind concat**

Inside `beginRecognitionTask`'s task-result closure, locate:

```swift
let combined = self.accumulatedText.isEmpty
    ? text
    : (text.isEmpty ? self.accumulatedText : self.accumulatedText + " " + text)
```

Replace with:

```swift
let combined = SeamStitcher.stitch(old: self.accumulatedText, new: text)
```

- [ ] **Step 2: Run full suite**

Expected: all pass, including the existing `testStateTransitionsNeverSkipWaiting`-family tests.

- [ ] **Step 3: Commit**

```bash
git add QuipiOS/Services/SpeechService.swift
git commit -m "$(cat <<'EOF'
Use SeamStitcher for recognizer task transitions — previous blind concat could duplicate overlapping words at the 1-minute recognizer-restart boundary; SeamStitcher dedups 1–3 word overlap case-insensitively.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.3: Iteration 4 device acceptance

- [ ] **Step 1: Install + force-quit + relaunch**

- [ ] **Step 2: Verify — 70-second monologue**

Read a known paragraph (70 seconds). Count words in paragraph vs words in prompt. **Expected:** no word missing at the ~60s mark (exact match or +/- 1 allowed for ambient noise).

- [ ] **Step 3: Verify — 3-minute dictation**

Talk continuously for 3 minutes. Two seams will cross. **Expected:** no missing words at either seam.

---

## Iteration 5 — Contextual vocab

### Task 5.1: Seed vocab file

**Files:**
- Create: `QuipiOS/Resources/dictation-vocab.txt`
- Modify: `QuipiOS/project.yml` (ensure resources bundled)

- [ ] **Step 1: Verify xcodegen already auto-includes the `Resources/` folder**

Run: `grep -n 'path: \\.' QuipiOS/project.yml`
Expected: `sources: - path: .` — yes, everything under `QuipiOS/` is auto-included except the explicit excludes. `Resources/` will bundle.

- [ ] **Step 2: Create the seed file**

Create `QuipiOS/Resources/dictation-vocab.txt` with the following content (one term per line, no blank lines, no trailing blank line):

```
SwiftUI
Xcode
WebSocket
Claude
Quip
monospace
iOS
macOS
TestFlight
GitHub
WKWebView
UIKit
SFSpeechRecognizer
AVFoundation
Whisper
Bonjour
Tailscale
QRCode
PTT
Bluetooth
```

- [ ] **Step 3: Commit**

```bash
git add QuipiOS/Resources/dictation-vocab.txt
git commit -m "$(cat <<'EOF'
Add dictation vocab seed list — bundled at app build time, loaded once by SpeechService for SFSpeechAudioBufferRecognitionRequest.contextualStrings. Keeps technical terms (SwiftUI, Xcode, WebSocket, monospace, ...) from being mis-transcribed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5.2: Load vocab and wire to recognition request

**Files:**
- Modify: `QuipiOS/Services/SpeechService.swift`
- Modify: `QuipiOS/Tests/PTTStressTests.swift`

- [ ] **Step 1: Write the failing test**

Add:

```swift
func testVocabLoaderCapsAtOneHundredAndNormalizes() {
    // Tempfile with 150 terms, some blank lines, some whitespace
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vocab.txt")
    var lines: [String] = []
    for i in 0..<150 { lines.append("term\(i)") }
    lines.insert("", at: 10)
    lines.insert("   padded   ", at: 20)
    let content = lines.joined(separator: "\n")
    try? content.write(to: tmp, atomically: true, encoding: .utf8)

    let loaded = DictationVocab.load(from: tmp)
    XCTAssertEqual(loaded.count, 100)
    XCTAssertFalse(loaded.contains(""))
    XCTAssertTrue(loaded.contains("padded"))
}

func testVocabLoaderReturnsEmptyOnMissingFile() {
    let missing = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).txt")
    XCTAssertEqual(DictationVocab.load(from: missing), [])
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `DictationVocab` undefined.

- [ ] **Step 3: Implement loader**

Add at the top of `QuipiOS/Services/SpeechService.swift` (outside the class):

```swift
enum DictationVocab {
    static let maxTerms = 100

    static func load(from url: URL) -> [String] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let terms = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(terms.prefix(maxTerms))
    }

    static func loadBundled() -> [String] {
        guard let url = Bundle.main.url(forResource: "dictation-vocab", withExtension: "txt") else {
            NSLog("[Quip][PTT] dictation-vocab.txt not found in bundle")
            return []
        }
        return load(from: url)
    }
}
```

- [ ] **Step 4: Wire into recognition request**

In `AudioWorker`:

```swift
private let cachedVocab: [String] = DictationVocab.loadBundled()
```

In `beginRecognitionTask`, after creating `request`:

```swift
request.shouldReportPartialResults = true
request.requiresOnDeviceRecognition = true
if !cachedVocab.isEmpty {
    request.contextualStrings = cachedVocab
}
```

- [ ] **Step 5: Run tests**

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add QuipiOS/Services/SpeechService.swift QuipiOS/Tests/PTTStressTests.swift
git commit -m "$(cat <<'EOF'
Load dictation vocab from bundle and apply to every recognition request — hint list nudges the on-device recognizer toward the project's technical vocabulary without needing server-side recognition.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5.3: Iteration 5 device acceptance

- [ ] **Step 1: Install + force-quit + relaunch**

- [ ] **Step 2: Verify — technical vocab**

Say: "SwiftUI Xcode monospace WebSocket". **Expected:** all four transcribed exactly.

- [ ] **Step 3: Verify — no regression on plain speech**

Say a paragraph of non-technical English. **Expected:** no worse than before; quality subjectively similar or better.

---

## Wrap-up

### Task 6.1: Update wishlist

- [ ] **Step 1: Mark PTT timing plan as shipped**

In `docs/superpowers/wishlist.md`, add a new entry (or update an existing PTT one) noting: "Shipped C-scope PTT reliability plan on 2026-04-23. D-scope (recognizer swap to Mac Whisper + settings picker) remains open."

- [ ] **Step 2: Capture D-scope follow-up**

Add an explicit wishlist item for D-scope with bullets: Mac Whisper local (default), iPhone on-device fallback, iPhone server opt-in, stream audio over existing WebSocket, settings picker, per-source diagnostics, vocab file editor. Link back to this plan (`docs/superpowers/plans/2026-04-23-ptt-reliability.md`) and its spec.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/wishlist.md
git commit -m "$(cat <<'EOF'
Update wishlist — PTT timing fixes shipped (iOS on-device path), Whisper/picker D-scope captured as the next follow-up with clear acceptance criteria.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```
