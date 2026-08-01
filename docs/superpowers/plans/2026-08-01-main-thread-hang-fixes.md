# Main-Thread Hang Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop QuipMac from freezing (macOS hang reports up to 913s) by removing every blocking subprocess spawn and blocking TCC probe from the main thread.

**Architecture:** Two independent root causes, both "blocking system call on the MainActor". (1) `TerminalStateDetector` forks `/bin/ps` on the main thread from the kqueue child-exit handler and from the on-demand CLI re-classify path; the fix is to serve those paths from the snapshot the off-main poll loop already captures every 250 ms, and to make the exit handler pure bookkeeping. (2) `PermissionProbeService.probe()` runs `AEDeterminePermissionToAutomateTarget` — a semaphore-blocking Apple Events round-trip — synchronously on main, driven by a 5 s timer and a 3 s SwiftUI `TimelineView`; the fix is an off-main, coalescing, injectable probe service whose result lands on main.

**Tech Stack:** Swift 6 (app target), XCTest, XcodeGen, GCD (`DispatchQueue`, `DispatchSourceProcess`), `NSLock`.

## Evidence (why these files)

macOS hang reports in `/Library/Logs/DiagnosticReports/`:

| Report | Duration | Main-thread stack |
|---|---|---|
| `Quip_2026-08-01-131028` | **913.97s** | `TerminalStateDetector.refreshChildWatches` → `captureProcessSnapshot` → `NSConcreteTask` |
| `Quip_2026-08-01-131855` | 3.23s | same |
| `Quip_2026-07-27-094944` | 85.42s | same |
| `Quip_2026-07-30-091540` | 6.30s | `broadcastPermissions` → `probeAppleEventsForITerm` → `AEDeterminePermissionToAutomateTarget` → `_dispatch_semaphore_wait_slow` |

Plus three `Quip_*.cpu_resource.diag` reports: "90 seconds cpu time over 95 seconds (95% cpu average)". No `.ips` crash reports exist — the app never crashed, it froze and was force-quit.

Regression origin: commit `eaeb380` (2026-06-03) moved the poll loop off the main thread but left the kqueue exit path (added in `a2454d5`, 2026-04-10) calling `ps` on main.

## Global Constraints

- App target `QuipMac` builds `SWIFT_VERSION: 6` (`QuipMac/project.yml:10`). Test target `QuipMacTests` pins `SWIFT_VERSION: "5"` + `SWIFT_STRICT_CONCURRENCY: minimal` (`QuipMac/project.yml:91-94`). Do not change either.
- App `PRODUCT_NAME` is `Quip`, so all tests use `@testable import Quip` — never `import QuipMac`.
- All tests are XCTest. There is no swift-testing (`import Testing`) anywhere in the repo. Match the existing style: `final class XxxTests: XCTestCase`, `@MainActor` on the class when the subject is main-actor-isolated.
- New test files go in `QuipMac/Tests/`. They are picked up by `path: Tests` in `QuipMac/project.yml:77`.
- **New files are not in the committed `project.pbxproj`.** Before any build or test run: `cd QuipMac && xcodegen generate`. Before committing: `git checkout QuipMac/QuipMac.xcodeproj/project.pbxproj` so the generated churn stays out of the diff.
- **Quit the running Quip.app before running tests locally** — the app-hosted test runner binds port 8765 and will collide with a live instance. `killall -KILL Quip` if it traps SIGTERM.
- Run Mac tests **signed** locally. Do not pass `CODE_SIGNING_ALLOWED=NO` locally; it hangs the app-hosted runner under the hardened runtime. (CI passes it because CI has no keychain.)
- **`xcodebuild` is the only reliable actor-isolation oracle.** SourceKit/IDE diagnostics under-report Swift 6 isolation errors. Never claim "it compiles" without an actual `xcodebuild` run.
- `DEVELOPMENT_TEAM` stays `D2PM6R797Q` (Fintech Adventures LLC). Do not touch signing config.
- Do not rebuild/reinstall the Mac app as part of a task step — each Mac reinstall costs the user their Accessibility and Screen Recording TCC grants. Build and test only; installation is a separate decision at the end.

**Canonical test command** (run from repo root):

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/<SuiteName> \
  2>&1 | tail -30
```

**Full suite** (baseline before this plan: 636 tests, 0 failures, ~9.7s):

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' 2>&1 | tail -30
```

---

## File Structure

**Modified:**
- `QuipMac/Services/TerminalStateDetector.swift` — Tasks 1, 2, 3, 5. Snapshot instrumentation, snapshot cache, exit-handler simplification, dead-code removal.
- `QuipMac/Services/PermissionProbeService.swift` — Task 4. Rewritten as an off-main, coalescing, injectable service.
- `QuipMac/QuipMacApp.swift` — Task 4 (async permission broadcast), Task 6 (Settings environment wiring).
- `QuipMac/Views/SettingsView.swift` — Task 6. Drop the duplicate probe + 3s blocking `TimelineView`.
- `QuipMac/Services/LogPaths.swift` — Task 7. Size-bounded log rotation.

**Created:**
- `QuipMac/Tests/TerminalStateDetectorMainThreadTests.swift` — Tasks 1, 2, 3.
- `QuipMac/Tests/PermissionProbeServiceTests.swift` — Task 4.
- `QuipMac/Tests/LogRotationTests.swift` — Task 7.

---

### Task 1: Instrument main-thread `ps` spawns (the failing-test harness)

Nothing in this codebase can currently observe "we forked a subprocess on the main thread". Every later task in this plan asserts against that fact, so build the observation seam first. This task adds the counter and one test that **fails today** — proving the bug is real before we touch behavior.

**Files:**
- Modify: `QuipMac/Services/TerminalStateDetector.swift:533-553` (`captureProcessSnapshot`), `:172-203` (`shellPidForTTY`)
- Create: `QuipMac/Tests/TerminalStateDetectorMainThreadTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `TerminalStateDetector.mainThreadProcessSpawns: Int` — read-only count of `Process()` launches that happened while `Thread.isMainThread` was true. `nonisolated(unsafe) static private(set)`.
  - `TerminalStateDetector.resetMainThreadProcessSpawnCount()` — `nonisolated static func`, test-only reset.

- [ ] **Step 1: Add the counter to `TerminalStateDetector`**

Insert immediately above the `// MARK: - Start / Stop Monitoring` comment (currently `TerminalStateDetector.swift:76`):

```swift
    // MARK: - Main-Thread Spawn Instrumentation

    /// Number of times we forked a subprocess (`ps`) while on the main thread.
    ///
    /// Blocking `Process.run()` + `readDataToEndOfFile()` on main is what
    /// produced the 913-second hang in `Quip_2026-08-01-131028.hang`. This
    /// counter is the regression oracle: it must stay at zero for every code
    /// path that can be reached from the MainActor. `nonisolated(unsafe)`
    /// because the spawn sites are `nonisolated` and the counter is only ever
    /// incremented from the main thread (where the bug lives) — a racing
    /// off-main spawn never touches it.
    nonisolated(unsafe) private(set) static var mainThreadProcessSpawns = 0

    /// Test-only reset so each case starts from a known count.
    nonisolated static func resetMainThreadProcessSpawnCount() {
        mainThreadProcessSpawns = 0
    }

    /// Call at every `Process()` launch site. No-op off main.
    nonisolated static func noteProcessSpawn() {
        if Thread.isMainThread { mainThreadProcessSpawns += 1 }
    }
```

- [ ] **Step 2: Call it at both spawn sites**

In `captureProcessSnapshot()`, immediately before `do { try task.run() }` (currently `TerminalStateDetector.swift:542`):

```swift
        noteProcessSpawn()
        do {
            try task.run()
        } catch {
```

In `shellPidForTTY(_:)`, replace the existing launch line (currently `TerminalStateDetector.swift:179`):

```swift
        noteProcessSpawn()
        do { try task.run() } catch { return nil }
```

- [ ] **Step 3: Write the failing test**

Create `QuipMac/Tests/TerminalStateDetectorMainThreadTests.swift`:

```swift
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
```

- [ ] **Step 4: Run the test — it MUST fail**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/TerminalStateDetectorMainThreadTests \
  2>&1 | tail -30
```

Expected: FAIL — `XCTAssertEqual failed: ("1") is not equal to ("0") - refreshCLIKind forked ps on the main thread`. (Count may be 2 if `detectState` also falls through to `shellPidForTTY`.)

If it PASSES, stop — the instrumentation is not wired to the real spawn sites. Re-check Step 2.

- [ ] **Step 5: Commit**

```bash
git checkout QuipMac/QuipMac.xcodeproj/project.pbxproj
git add QuipMac/Services/TerminalStateDetector.swift QuipMac/Tests/TerminalStateDetectorMainThreadTests.swift
git commit -m "test: prove TerminalStateDetector forks ps on the main thread

Adds a main-thread spawn counter at both Process() launch sites and a
failing test against refreshCLIKind. This is the regression oracle for the
913s hang in Quip_2026-08-01-131028.hang."
```

---

### Task 2: Publish the poll loop's snapshot to a thread-safe cache

The off-main poll loop already captures a full `ps -ax` snapshot every 250 ms (`TerminalStateDetector.swift:103`) and then throws it away. Store it instead, so main-thread callers can read a ≤250 ms-old answer without forking anything.

**Files:**
- Modify: `QuipMac/Services/TerminalStateDetector.swift` — add cache type near `ProcessSnapshot` (`:490-511`), store at `:103`, add reader
- Test: `QuipMac/Tests/TerminalStateDetectorMainThreadTests.swift` (extend)

**Interfaces:**
- Consumes: `TerminalStateDetector.ProcessSnapshot` (private nested struct, `:490`).
- Produces:
  - `TerminalStateDetector.SnapshotCache` — `private final class`, `@unchecked Sendable`, methods `store(_ snapshot: ProcessSnapshot?, at: Date)` and `read(maxAge: TimeInterval, now: Date) -> ProcessSnapshot?`.
  - `TerminalStateDetector.snapshotCache` — `private let` instance.
  - `TerminalStateDetector.hasFreshSnapshot(maxAge: TimeInterval) -> Bool` — `internal`, for tests.

- [ ] **Step 1: Write the failing test**

Append to `QuipMac/Tests/TerminalStateDetectorMainThreadTests.swift`, inside the class:

```swift
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/TerminalStateDetectorMainThreadTests/test_pollLoop_publishesSnapshotToCache \
  2>&1 | tail -30
```

Expected: FAIL to **compile** — `value of type 'TerminalStateDetector' has no member 'hasFreshSnapshot'`. A compile failure is a valid red state here.

- [ ] **Step 3: Add the cache type**

Insert immediately after the closing brace of `private struct ProcessSnapshot` (currently ends `TerminalStateDetector.swift:511`):

```swift
    /// Thread-safe holder for the newest `ps` snapshot.
    ///
    /// The poll loop captures one every 250 ms on `pollQueue`; main-thread
    /// callers read it instead of forking their own `ps`. `@unchecked
    /// Sendable` is sound because every access goes through `lock`.
    private final class SnapshotCache: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: ProcessSnapshot?
        private var capturedAt: Date?

        func store(_ snapshot: ProcessSnapshot?, at date: Date) {
            lock.lock()
            defer { lock.unlock() }
            // A nil capture means ps failed; keep the previous good snapshot
            // rather than blanking the cache and forcing callers to guess.
            guard let snapshot else { return }
            self.snapshot = snapshot
            self.capturedAt = date
        }

        func read(maxAge: TimeInterval, now: Date) -> ProcessSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            guard let capturedAt, now.timeIntervalSince(capturedAt) <= maxAge else { return nil }
            return snapshot
        }
    }
```

- [ ] **Step 4: Add the instance property and the test accessor**

Add next to the other private stored properties, immediately after `private var knownChildren: [String: Set<pid_t>] = [:]` (currently `TerminalStateDetector.swift:74`):

```swift
    /// Newest snapshot published by the poll loop. Read by main-thread
    /// callers so they never fork `ps` themselves.
    private let snapshotCache = SnapshotCache()

    /// Test seam: has the poll loop published a snapshot recently enough?
    func hasFreshSnapshot(maxAge: TimeInterval) -> Bool {
        snapshotCache.read(maxAge: maxAge, now: Date()) != nil
    }
```

- [ ] **Step 5: Store the snapshot in the poll loop**

Replace the capture line in `startMonitoring` (currently `TerminalStateDetector.swift:103`):

```swift
                let processSnapshot = Self.captureProcessSnapshot()
                self.snapshotCache.store(processSnapshot, at: Date())
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/TerminalStateDetectorMainThreadTests/test_pollLoop_publishesSnapshotToCache \
  2>&1 | tail -30
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git checkout QuipMac/QuipMac.xcodeproj/project.pbxproj
git add QuipMac/Services/TerminalStateDetector.swift QuipMac/Tests/TerminalStateDetectorMainThreadTests.swift
git commit -m "feat: publish poll-loop ps snapshot to a thread-safe cache

The off-main poll loop already captures a full process snapshot every
250ms and discards it. Store it so main-thread callers can read a fresh
answer without forking ps themselves."
```

---

### Task 3: Serve main-thread callers from the cache; make the exit handler pure bookkeeping

This is the fix for the three 913s/85s/3s hangs. Two changes:

1. **The kqueue exit handler stops running `ps` entirely.** `handleProcessEvent` → `refreshChildWatches` → `captureProcessSnapshot` was one full system-wide `ps -ax` **per child-process exit**, on main, serialized. A Claude session spawns children constantly. The 0.25 s poll loop already reconciles `knownChildren` wholesale and installs sources for new PIDs (`TerminalStateDetector.swift:143-150`), so the exit handler's work was pure redundancy — and it could never beat the 2-poll debounce (`debounceThreshold = 2`, `:307`) anyway, so removing it costs no responsiveness.
2. **`refreshCLIKind` reads the cache** instead of capturing, and stops `detectState` from falling through to the `shellPidForTTY` fork while on main.

**Files:**
- Modify: `QuipMac/Services/TerminalStateDetector.swift:247-286` (exit handler + `handleProcessEvent` + `refreshChildWatches`), `:420-436` (`detectState`), `:360-408` (`refreshCLIKind`)
- Test: `QuipMac/Tests/TerminalStateDetectorMainThreadTests.swift` (extend)

**Interfaces:**
- Consumes: `snapshotCache`, `hasFreshSnapshot(maxAge:)` (Task 2); `mainThreadProcessSpawns`, `resetMainThreadProcessSpawnCount()` (Task 1).
- Produces:
  - `TerminalStateDetector.handleProcessExit(windowId: String, pid: pid_t)` — `internal func`, replaces `handleProcessEvent`. Removes and cancels the source for `pid`; performs no I/O.
  - `detectState(shellPid:tty:cpuThreshold:snapshot:allowBlockingTTYResolve:)` — new trailing parameter, defaults `true`.
  - `refreshChildWatches(windowId:shellPid:)` is **deleted**.

- [ ] **Step 1: Write the failing tests**

Append to `QuipMac/Tests/TerminalStateDetectorMainThreadTests.swift`, inside the class:

```swift
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
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/TerminalStateDetectorMainThreadTests \
  2>&1 | tail -40
```

Expected: compile failure on `handleProcessExit` (does not exist yet), and once that is added, `test_refreshCLIKind_*` fail with a non-zero count.

- [ ] **Step 3: Replace the exit handler and delete `refreshChildWatches`**

Replace the whole block from `private func installProcessSource` through the end of `refreshChildWatches` (currently `TerminalStateDetector.swift:247-286`) with:

```swift
    private func installProcessSource(windowId: String, pid: pid_t) {
        // Skip if this PID is already being watched under this window.
        if processSources[windowId]?[pid] != nil { return }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleProcessExit(windowId: windowId, pid: pid)
            }
        }
        source.setCancelHandler {} // prevent crashes on dealloc
        source.resume()
        processSources[windowId, default: [:]][pid] = source
    }

    /// A watched child exited. Drop its kqueue source and stop — deliberately
    /// no I/O here.
    ///
    /// This used to call `refreshChildWatches`, which ran a full system-wide
    /// `ps -ax` synchronously **on the main thread, once per exit**. A Claude
    /// session spawns short-lived children constantly, so a burst of exits
    /// serialized into a burst of blocking forks: that is the stack in
    /// `Quip_2026-08-01-131028.hang` (913 seconds unresponsive) and the cause
    /// of the 95%-CPU `cpu_resource.diag` reports.
    ///
    /// Nothing is lost by removing it. The 0.25s poll loop reconciles
    /// `knownChildren` wholesale and installs sources for new PIDs
    /// (see `startMonitoring`), and state transitions require 2 agreeing polls
    /// (`debounceThreshold`) regardless — so an immediate re-poll could never
    /// have shortened the transition latency it was written to shorten.
    func handleProcessExit(windowId: String, pid: pid_t) {
        if let source = processSources[windowId]?.removeValue(forKey: pid) {
            source.cancel()
        }
        knownChildren[windowId]?.remove(pid)
    }
```

- [ ] **Step 4: Gate the blocking TTY re-resolve in `detectState`**

Replace the signature and the re-resolve branch (currently `TerminalStateDetector.swift:420-436`):

```swift
    private nonisolated func detectState(
        shellPid: pid_t,
        tty: String?,
        cpuThreshold: Double,
        snapshot: ProcessSnapshot? = nil,
        allowBlockingTTYResolve: Bool = true
    ) -> (TerminalState, Bool, CLIKind, pid_t?, [ProcessInfo]) {
        var resolvedPid: pid_t? = nil
        var children = childProcesses(of: shellPid, snapshot: snapshot)

        // Empty descendants for an iTerm2 window with a known TTY usually
        // means the original shell has exited and a new shell now owns the
        // session. Re-resolve via the stable TTY and try once more.
        //
        // `shellPidForTTY` forks `ps -t`, so callers already on the main
        // thread pass `allowBlockingTTYResolve: false` — a stale PID for one
        // poll cycle is strictly better than a main-thread fork.
        if allowBlockingTTYResolve,
           children.isEmpty, let tty, !tty.isEmpty,
           let liveShell = Self.shellPidForTTY(tty), liveShell != shellPid {
            resolvedPid = liveShell
            children = childProcesses(of: liveShell, snapshot: snapshot)
        }
```

Leave the rest of `detectState` unchanged.

- [ ] **Step 5: Make `refreshCLIKind` read the cache**

Replace the capture + detect block inside `refreshCLIKind` (currently `TerminalStateDetector.swift:371-378`):

```swift
        // Read the poll loop's snapshot (≤250ms old) instead of forking `ps`
        // here — this runs on the main thread from the press_return and
        // image_upload handlers, and a blocking fork here is what froze the
        // app. maxAge is 4x the poll interval so a single slow poll doesn't
        // strand us.
        guard let processSnapshot = snapshotCache.read(maxAge: 1.0, now: Date()) else {
            appendClassifyLog("refresh window=\(windowId) no-fresh-snapshot cached=\(windowCLIKind[windowId]?.rawValue ?? "none")")
            return windowCLIKind[windowId] ?? .shell
        }
        let (detected, hasClaude, cli, resolvedPid, children) = detectState(
            shellPid: shellPid,
            tty: trackedTty[windowId],
            cpuThreshold: cpuIdleThreshold,
            snapshot: processSnapshot,
            allowBlockingTTYResolve: false
        )
```

Leave the remainder of `refreshCLIKind` (the `resolvedPid` write-back, `applyPollResults`, `windowsWithClaudeProcess` update, `appendClassifyLog`, `knownChildren` reconcile, `return cli`) exactly as-is.

- [ ] **Step 6: Run the suite to verify it passes**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/TerminalStateDetectorMainThreadTests \
  2>&1 | tail -30
```

Expected: PASS, all 5 tests.

Then confirm no collateral damage in the existing classifier suite:

```bash
cd QuipMac && xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/CLIKindClassifierTests 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git checkout QuipMac/QuipMac.xcodeproj/project.pbxproj
git add QuipMac/Services/TerminalStateDetector.swift QuipMac/Tests/TerminalStateDetectorMainThreadTests.swift
git commit -m "fix: stop forking ps on the main thread in TerminalStateDetector

The kqueue child-exit handler ran a full system-wide ps -ax synchronously
on the main thread, once per exit. During a Claude session those exits
arrive in bursts and serialize, which is the 913-second hang in
Quip_2026-08-01-131028.hang and the 95%-CPU cpu_resource reports.

The exit handler is now pure bookkeeping — the 0.25s poll loop already
reconciles child watches wholesale, and the 2-poll debounce meant the
immediate re-poll could never shorten transition latency anyway.

refreshCLIKind now reads the poll loop's published snapshot and no longer
falls through to the blocking shellPidForTTY re-resolve while on main."
```

---

### Task 4: Move the TCC permission probe off the main thread

`PermissionProbeService.probe()` calls `AEDeterminePermissionToAutomateTarget`, which blocks on a dispatch semaphore waiting for an Apple Events round-trip to iTerm2 and the TCC daemon. It runs on the MainActor, driven by a 5 s repeating timer in `.common` mode. When iTerm2 or `tccd` is slow, main freezes for the duration — that is `Quip_2026-07-30-091540.hang` (6.30 s, all 35 samples inside `_dispatch_semaphore_wait_slow`).

**Files:**
- Modify: `QuipMac/Services/PermissionProbeService.swift` (whole file)
- Modify: `QuipMac/QuipMacApp.swift:726-749` (`broadcastPermissions`)
- Create: `QuipMac/Tests/PermissionProbeServiceTests.swift`

**Interfaces:**
- Consumes: `MacPermissionsMessage` (existing Shared type).
- Produces:
  - `PermissionProbeService.Probes` — injectable `struct` with three `@Sendable () -> Bool` closures: `accessibility`, `appleEvents`, `screenRecording`.
  - `PermissionProbeService.init(probes: Probes = .system)`
  - `PermissionProbeService.lastSnapshot: MacPermissionsMessage?` — non-blocking read of the newest completed probe.
  - `PermissionProbeService.refresh(completion: @escaping @MainActor (MacPermissionsMessage) -> Void)` — runs the three probes off main, delivers on main, coalesces concurrent requests.
  - `QuipMacApp.applyPermissionsSnapshot(_:force:)` — `@MainActor private func` holding the post-probe half of the old `broadcastPermissions`.

- [ ] **Step 1: Write the failing tests**

Create `QuipMac/Tests/PermissionProbeServiceTests.swift`:

```swift
import XCTest
@testable import Quip

/// Regression cover for Quip_2026-07-30-091540.hang: a 6.3-second freeze with
/// every sample inside AEDeterminePermissionToAutomateTarget's semaphore wait,
/// reached from a 5-second timer on the main thread.
final class PermissionProbeServiceTests: XCTestCase {

    /// The three TCC calls must not execute on the main thread. This is the
    /// whole point of the change: AEDeterminePermissionToAutomateTarget blocks
    /// on IPC and cannot be allowed to block the UI.
    func test_refresh_runsProbesOffMainThread() {
        let ranOnMain = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        ranOnMain.initialize(to: false)
        defer { ranOnMain.deallocate() }

        let probes = PermissionProbeService.Probes(
            accessibility: { if Thread.isMainThread { ranOnMain.pointee = true }; return true },
            appleEvents: { if Thread.isMainThread { ranOnMain.pointee = true }; return true },
            screenRecording: { if Thread.isMainThread { ranOnMain.pointee = true }; return true }
        )
        let service = PermissionProbeService(probes: probes)

        let done = expectation(description: "refresh completed")
        service.refresh { _ in done.fulfill() }
        wait(for: [done], timeout: 5.0)

        XCTAssertFalse(ranOnMain.pointee, "TCC probes ran on the main thread")
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

/// Lock-guarded counter — the probe closures run on a background queue.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/PermissionProbeServiceTests \
  2>&1 | tail -30
```

Expected: compile failure — `PermissionProbeService` has no `Probes`, no `init(probes:)`, no `refresh`, no `lastSnapshot`.

- [ ] **Step 3: Rewrite `PermissionProbeService`**

Replace the whole of `QuipMac/Services/PermissionProbeService.swift` with:

```swift
// PermissionProbeService.swift
// QuipMac — Probes the three TCC grants Quip needs and publishes the result.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Probes Accessibility, Automation (Apple Events) and Screen Recording.
///
/// Every probe runs **off the main thread**.
/// `AEDeterminePermissionToAutomateTarget` blocks on a dispatch semaphore
/// waiting for an Apple Events round-trip to the target app and `tccd`; when
/// either is slow the caller's thread stalls for seconds. Running that on main
/// from the 5-second permissions timer produced a 6.3-second UI freeze with
/// every sample inside `_dispatch_semaphore_wait_slow`
/// (`Quip_2026-07-30-091540.hang`).
///
/// Not `@MainActor` and not an actor: the blocking work belongs on a utility
/// queue, and the completion is hopped back to main explicitly.
final class PermissionProbeService: @unchecked Sendable {

    /// iTerm is the only app we drive via Apple Events, so it's the only
    /// Automation grant worth probing. Terminal.app uses keystroke injection
    /// (Accessibility), not Apple Events. If we ever script Terminal too,
    /// probe both. If a user is iTerm-less, the false-positive is preferable
    /// to a confusing red dot.
    static let iTermBundleID = "com.googlecode.iterm2"

    /// The three grant checks, injectable so tests can drive timing and
    /// outcomes without real TCC state.
    struct Probes: Sendable {
        var accessibility: @Sendable () -> Bool
        var appleEvents: @Sendable () -> Bool
        var screenRecording: @Sendable () -> Bool

        static let system = Probes(
            accessibility: { AXIsProcessTrusted() },
            appleEvents: { PermissionProbeService.systemAppleEventsProbe() },
            screenRecording: { CGPreflightScreenCaptureAccess() }
        )
    }

    private let probes: Probes
    private let queue = DispatchQueue(label: "quip.permission-probe", qos: .utility)
    private let lock = NSLock()
    private var cached: MacPermissionsMessage?
    private var inFlight = false
    private var waiters: [@MainActor (MacPermissionsMessage) -> Void] = []

    init(probes: Probes = .system) {
        self.probes = probes
    }

    /// Newest completed snapshot. Non-blocking; nil until the first refresh
    /// lands. SwiftUI view bodies read this rather than forcing a probe.
    var lastSnapshot: MacPermissionsMessage? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Run the three probes off main and deliver the result on main.
    ///
    /// Coalescing matters: the app's 5-second timer and the Settings tab can
    /// both ask while a slow Apple Events round-trip is still outstanding.
    /// Without this, those requests would pile onto the queue and each one
    /// would pay the full stall.
    func refresh(completion: @escaping @MainActor (MacPermissionsMessage) -> Void) {
        lock.lock()
        waiters.append(completion)
        if inFlight {
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()

        queue.async { [self] in
            let snapshot = MacPermissionsMessage(
                accessibility: probes.accessibility(),
                appleEvents: probes.appleEvents(),
                screenRecording: probes.screenRecording()
            )

            lock.lock()
            cached = snapshot
            inFlight = false
            let pending = waiters
            waiters.removeAll()
            lock.unlock()

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for waiter in pending { waiter(snapshot) }
                }
            }
        }
    }

    /// Returns false ONLY when the user has explicitly denied Apple Events for
    /// the target. `procNotFound` (target not running) is treated as granted —
    /// we can't tell, and the alternative is permanent red until iTerm
    /// launches. Blocking: only ever called from `queue`.
    private static func systemAppleEventsProbe() -> Bool {
        guard let bundleData = iTermBundleID.data(using: .utf8) else { return true }

        var addressDesc = AEAddressDesc()
        let createStatus: OSStatus = bundleData.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return OSStatus(Int(errAEWrongDataType)) }
            return OSStatus(AECreateDesc(typeApplicationBundleID, base, bundleData.count, &addressDesc))
        }
        guard createStatus == noErr else { return true }
        defer { AEDisposeDesc(&addressDesc) }

        let result = AEDeterminePermissionToAutomateTarget(
            &addressDesc,
            typeWildCard,
            typeWildCard,
            false  // askUserIfNeeded — silent probe
        )
        switch result {
        case noErr: return true
        case OSStatus(procNotFound): return true
        case OSStatus(errAEEventNotPermitted): return false
        default: return true
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/PermissionProbeServiceTests \
  2>&1 | tail -30
```

Expected: PASS, all 4 tests.

- [ ] **Step 5: Split `broadcastPermissions` into request + apply**

In `QuipMac/QuipMacApp.swift`, replace `broadcastPermissions(force:)` (currently `:726-749`) with:

```swift
    /// Probe + broadcast permissions. `force` skips the equality check (used at
    /// client-auth time so a freshly-connected phone always gets the current state).
    ///
    /// The probe runs off main — `AEDeterminePermissionToAutomateTarget` blocks
    /// on Apple Events IPC and froze the UI for 6.3 seconds when it ran inline
    /// here (`Quip_2026-07-30-091540.hang`).
    @MainActor
    private func broadcastPermissions(force: Bool) {
        permissionProbe.refresh { snapshot in
            applyPermissionsSnapshot(snapshot, force: force)
        }
    }

    @MainActor
    private func applyPermissionsSnapshot(_ snapshot: MacPermissionsMessage, force: Bool) {
        if snapshot.deniedCount == 0 {
            permissionsStore.permissionsNeedAttention = false
        } else if let previous = lastPermissionsSnapshot,
                  snapshot.deniedCount > previous.deniedCount {
            permissionsStore.permissionsNeedAttention = true
        }
        permissionsStore.snapshot = snapshot
        if !force, snapshot == lastPermissionsSnapshot { return }
        lastPermissionsSnapshot = snapshot
        webSocketServer.broadcast(snapshot)
    }
```

Preserve verbatim any lines of the original body that this plan's excerpt elides — read `QuipMacApp.swift:726-749` before editing and carry every statement between `let snapshot = permissionProbe.probe()` and the closing brace into `applyPermissionsSnapshot`, in order.

Note the ordering consequence at `QuipMacApp.swift:716-721`: that code comments "(force:true above), so `permissionsStore` holds the fresh snapshot". It no longer does, because the probe is now asynchronous. Move that dependent logic into `applyPermissionsSnapshot`, or re-read `permissionsStore.deniedCount` from inside the completion.

- [ ] **Step 6: Build and run the full suite**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: PASS, ≥636 tests, 0 failures. `xcodebuild` is the only trustworthy actor-isolation check here — `MainActor.assumeIsolated` and the `@MainActor` closure stored in `waiters` are exactly the shapes SourceKit mis-reports.

- [ ] **Step 7: Commit**

```bash
git checkout QuipMac/QuipMac.xcodeproj/project.pbxproj
git add QuipMac/Services/PermissionProbeService.swift QuipMac/QuipMacApp.swift QuipMac/Tests/PermissionProbeServiceTests.swift
git commit -m "fix: run TCC permission probes off the main thread

AEDeterminePermissionToAutomateTarget blocks on an Apple Events round-trip
to iTerm2 and tccd. Running it inline on the MainActor from the 5-second
permissions timer froze the UI for 6.3 seconds with every sample inside
_dispatch_semaphore_wait_slow (Quip_2026-07-30-091540.hang).

PermissionProbeService now runs all three grant checks on a utility queue,
coalesces concurrent requests so a slow round-trip can't stack, and
delivers the snapshot back on main. Probes are injectable so the off-main
guarantee is under test."
```

---

### Task 5: Delete the dead `pollAllWindows`

`pollAllWindows()` (`TerminalStateDetector.swift:333-354`) has no callers — the only occurrence of its name outside the declaration is a stale doc comment at `:269`, which Task 3 already rewrote. It contains the same main-thread `captureProcessSnapshot()` defect and would reintroduce the hang the moment someone wired it up.

**Files:**
- Modify: `QuipMac/Services/TerminalStateDetector.swift:333-354`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Confirm it is genuinely dead**

```bash
grep -rn "pollAllWindows" --include="*.swift" /Users/erickbzovi/Projects/Quip
```

Expected: exactly one hit, the `private func pollAllWindows()` declaration. If any call site appears, **stop** and convert it to the snapshot-cache pattern from Task 3 instead of deleting.

- [ ] **Step 2: Delete the function**

Remove `private func pollAllWindows() { ... }` in full (currently `TerminalStateDetector.swift:333-354`).

- [ ] **Step 3: Build and run the suite**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: PASS, 0 failures.

- [ ] **Step 4: Commit**

```bash
git checkout QuipMac/QuipMac.xcodeproj/project.pbxproj
git add QuipMac/Services/TerminalStateDetector.swift
git commit -m "refactor: delete dead pollAllWindows

No callers since the poll loop moved off-main in eaeb380. It still forked
ps on the MainActor, so leaving it in place is a loaded gun."
```

---

### Task 6: Stop the Settings tab from probing TCC every 3 seconds on main

`SettingsView` holds its own `PermissionProbeService` (`SettingsView.swift:810`) and calls `probe()` inside a `TimelineView(.periodic(by: 3.0))` **body** (`SettingsView.swift:820-821`). A SwiftUI view body runs on main, so while the General tab is open the app takes the blocking Apple Events round-trip every 3 seconds on top of the app's own 5-second timer.

After Task 4 that call no longer exists. Point the view at the shared store the app already maintains.

**Files:**
- Modify: `QuipMac/QuipMacApp.swift:274-284` (Settings `Window` scene)
- Modify: `QuipMac/Views/SettingsView.swift:805-826`

**Interfaces:**
- Consumes: `MacPermissionsStore` (`QuipMac/Services/MacPermissionsStore.swift`, `@Observable @MainActor final class`), already instantiated at `QuipMacApp.swift:193`.
- Produces: nothing.

- [ ] **Step 1: Inject the store into the Settings scene**

In `QuipMacApp.swift`, add one modifier to the `SettingsView()` chain in the `Window("Settings", id: quipSettingsWindowID)` scene (currently `:274-284`), matching the existing style:

```swift
                .environment(permissionsStore)
```

- [ ] **Step 2: Replace the view's private probe with the store**

In `QuipMac/Views/SettingsView.swift`, delete the stored probe and its comment (currently `:805-810`):

```swift
    /// Re-probe TCC perms every 3s while this tab is visible so the row
    /// status flips green within seconds of the user granting in System
    /// Settings — without forcing the user to bounce back into Quip to
    /// see it. TimelineView is the cheapest reactive timer in SwiftUI.
    private let permissionProbe = PermissionProbeService()
```

Add, alongside the view's other `@Environment` declarations:

```swift
    @Environment(MacPermissionsStore.self) private var permissionsStore
```

- [ ] **Step 3: Read the store instead of probing in the body**

Replace the `TimelineView` block (currently `SettingsView.swift:820-824`):

```swift
                // Rows track `permissionsStore`, which the app refreshes every
                // 5s off the main thread. Probing here instead would run a
                // blocking Apple Events round-trip inside a SwiftUI body on
                // main — see Quip_2026-07-30-091540.hang.
                let perms = permissionsStore.snapshot
                macPermRow(name: "Accessibility", granted: perms?.accessibility ?? true, pane: .accessibility)
                macPermRow(name: "Automation (iTerm)", granted: perms?.appleEvents ?? true, pane: .automation)
                macPermRow(name: "Screen Recording", granted: perms?.screenRecording ?? true, pane: .screenRecording)
```

Before writing this, read `MacPermissionsStore.swift` and confirm whether `snapshot` is `MacPermissionsMessage?` or non-optional; drop the `?? true` defaults if it is non-optional. `QuipMacApp.swift:745` assigns it directly, so the type is whatever that property declares.

- [ ] **Step 4: Build and run the suite**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: PASS, 0 failures. A missing `.environment(permissionsStore)` compiles fine and crashes at runtime when the window opens — so also confirm the modifier from Step 1 is present before moving on.

- [ ] **Step 5: Commit**

```bash
git checkout QuipMac/QuipMac.xcodeproj/project.pbxproj
git add QuipMac/QuipMacApp.swift QuipMac/Views/SettingsView.swift
git commit -m "fix: Settings permissions rows read the store instead of probing on main

SettingsView ran a blocking Apple Events TCC probe inside a
TimelineView(.periodic(by: 3.0)) body — i.e. on the main thread, every 3
seconds, whenever the General tab was open, stacked on top of the app's
own 5s timer. The rows now track MacPermissionsStore, which the app
refreshes off-main."
```

---

### Task 7: Bound the diagnostic logs

`~/Library/Logs/Quip/push.log` is **231 MB** and `kokoro.log` is **27.6 MB**; `LogPaths.swift` has no rotation of any kind. This did not cause the hangs, but every append-only writer in the app seeks to the end of these files, and unbounded growth on a disk with 47 GB free is its own eventual failure.

**Files:**
- Modify: `QuipMac/Services/LogPaths.swift`
- Create: `QuipMac/Tests/LogRotationTests.swift`

**Interfaces:**
- Consumes: existing `LogPaths` path accessors.
- Produces: `LogPaths.rotateIfNeeded(path: String, maxBytes: Int) -> Bool` — `static func`, returns true when a rotation happened.

- [ ] **Step 1: Write the failing test**

Create `QuipMac/Tests/LogRotationTests.swift`:

```swift
import XCTest
@testable import Quip

final class LogRotationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quip-log-rotation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func test_rotateIfNeeded_leavesSmallFileAlone() throws {
        let path = dir.appendingPathComponent("small.log").path
        try String(repeating: "x", count: 100).write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertFalse(LogPaths.rotateIfNeeded(path: path, maxBytes: 1024))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".1"))
    }

    func test_rotateIfNeeded_movesOversizedFileToDotOne() throws {
        let path = dir.appendingPathComponent("big.log").path
        try String(repeating: "x", count: 5000).write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertTrue(LogPaths.rotateIfNeeded(path: path, maxBytes: 1024))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".1"))
    }

    /// Only one generation is kept — two rotations must not leave a .2 behind.
    func test_rotateIfNeeded_overwritesPreviousGeneration() throws {
        let path = dir.appendingPathComponent("big.log").path
        try String(repeating: "a", count: 5000).write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(LogPaths.rotateIfNeeded(path: path, maxBytes: 1024))

        try String(repeating: "b", count: 5000).write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(LogPaths.rotateIfNeeded(path: path, maxBytes: 1024))

        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".2"))
        let rolled = try String(contentsOfFile: path + ".1", encoding: .utf8)
        XCTAssertEqual(rolled.first, "b", "the newer generation should have replaced the older")
    }

    func test_rotateIfNeeded_missingFileIsNotAnError() {
        let path = dir.appendingPathComponent("absent.log").path
        XCTAssertFalse(LogPaths.rotateIfNeeded(path: path, maxBytes: 1024))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/LogRotationTests 2>&1 | tail -30
```

Expected: compile failure — `type 'LogPaths' has no member 'rotateIfNeeded'`.

- [ ] **Step 3: Implement rotation**

Add to `QuipMac/Services/LogPaths.swift`, inside the `LogPaths` type:

```swift
    /// Default ceiling for a single diagnostic log. Past this, the file is
    /// rolled to `<path>.1` and a fresh one starts. One generation is kept:
    /// these are debugging breadcrumbs, not an audit trail, and push.log had
    /// reached 231 MB unbounded.
    static let maxLogBytes = 16 * 1024 * 1024

    /// Roll `path` to `path + ".1"` when it exceeds `maxBytes`. Any previous
    /// `.1` is replaced. Returns true when a rotation happened.
    ///
    /// Failures are swallowed: a logger must never take the app down. If the
    /// move fails the file simply keeps growing, which is the status quo.
    @discardableResult
    static func rotateIfNeeded(path: String, maxBytes: Int = maxLogBytes) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              size > maxBytes else { return false }

        let rolled = path + ".1"
        try? fm.removeItem(atPath: rolled)
        do {
            try fm.moveItem(atPath: path, toPath: rolled)
            return true
        } catch {
            return false
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/LogRotationTests 2>&1 | tail -30
```

Expected: PASS, all 4 tests.

- [ ] **Step 5: Call it from the append sites**

Find every function that appends to a `LogPaths` path:

```bash
grep -rn "FileHandle(forWritingAtPath:" --include="*.swift" /Users/erickbzovi/Projects/Quip/QuipMac
```

In each one, call `LogPaths.rotateIfNeeded(path: path)` immediately before opening the handle. For example in `TerminalStateDetector.swift:12-23` (`appendClassifyLog`):

```swift
    let path = LogPaths.classifyPath
    LogPaths.rotateIfNeeded(path: path)
    if let handle = FileHandle(forWritingAtPath: path) {
```

Apply the identical two-line shape to each append helper found by the grep. Do not restructure the helpers otherwise.

- [ ] **Step 6: Build and run the full suite**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: PASS, 0 failures.

- [ ] **Step 7: Commit**

```bash
git checkout QuipMac/QuipMac.xcodeproj/project.pbxproj
git add QuipMac/Services/LogPaths.swift QuipMac/Tests/LogRotationTests.swift QuipMac/Services/TerminalStateDetector.swift
git commit -m "feat: bound diagnostic logs at 16 MiB with one rolled generation

push.log had reached 231 MB and kokoro.log 27.6 MB with no rotation
anywhere in LogPaths. Every append site now rolls the file past the
ceiling and keeps a single .1 generation."
```

---

---

## Tier 2 — same defect class, not implicated in the captured hangs

Tasks 1-7 fix every stack that appears in an actual hang report. A full sweep of `QuipMac/` found three more main-thread blockers with the same shape and comparable exposure. They have no hang report against them **yet**; they are ranked by how often they run.

### Task 8: Move the 0.4 s frontmost-window Accessibility poll off main

`currentFrontmostManagedWindowId()` (`QuipMacApp.swift:3226-3241`, `@MainActor`) makes two synchronous `AXUIElementCopyAttributeValue` round-trips **into whatever app is frontmost**. It is driven by `frontmostTimer` at `QuipMacApp.swift:500-505` — every 0.4 s, `.common` mode, for the life of the app. An AX round-trip into an unresponsive target blocks the caller until the AX timeout (seconds), which is the same 6-second shape as the Apple Events hang in Task 4.

**Files:**
- Modify: `QuipMac/QuipMacApp.swift:500-505` (timer), `:3226-3241` (`currentFrontmostManagedWindowId`), `:3263` (`broadcastFrontmostIfChanged`)

**Interfaces:**
- Produces: `currentFrontmostManagedWindowId()` becomes `nonisolated` and takes the window list as a plain value parameter; `broadcastFrontmostIfChanged()` snapshots MainActor state, hops to a utility queue for the AX calls, and hops back to compare-and-broadcast.

- [ ] **Step 1:** Read `QuipMacApp.swift:3220-3270` in full. Identify exactly which MainActor state `currentFrontmostManagedWindowId` reads (`windowManager.windows` and any id maps).
- [ ] **Step 2:** Follow the pattern already proven correct in this file at `QuipMacApp.swift:629-668` (the 2 s window-snapshot poll): `MainActor.assumeIsolated` to snapshot the needed state into local values, `DispatchQueue.global(qos: .utility).async` for the AX work, `DispatchQueue.main.async` to apply. Add a re-entrancy guard so a stalled AX call cannot let a second poll start — mirror `beginWindowPoll()` at `QuipMacApp.swift:629`.
- [ ] **Step 3:** Build: `cd QuipMac && xcodegen generate && xcodebuild build -project QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS' 2>&1 | tail -20`. Expected: BUILD SUCCEEDED.
- [ ] **Step 4:** Run the full suite. Expected: 0 failures.
- [ ] **Step 5:** Commit: `fix: run the frontmost-window AX poll off the main thread`.

### Task 9: Stop re-reading the whole tunnel log on main every second

`CloudflareTunnel.checkLogForURL()` (`CloudflareTunnel.swift:313`) does `String(contentsOfFile: Self.logPath)` and splits the entire file, on main, from a 1.0 s timer (`CloudflareTunnel.swift:256-261`). The timer only invalidates once `publicURL` is non-empty — so if cloudflared never resolves a URL, this loops forever against a file that keeps growing.

**Files:**
- Modify: `QuipMac/Services/CloudflareTunnel.swift:256-261`, `:313`

- [ ] **Step 1:** Move the read to a utility queue and hop the parsed URL back to main, same shape as Task 8 Step 2.
- [ ] **Step 2:** Read incrementally from a stored byte offset rather than slurping the whole file — `FileHandle.seek(toOffset:)` + `readToEnd()`. Follow the working example already in this repo: `SwrmEventTailer.readIncremental(...)` at `SwrmEventTailer.swift:123-140`.
- [ ] **Step 3:** Add a hard cap on the polling window so a tunnel that never resolves stops re-reading forever.
- [ ] **Step 4:** Build + full suite. Expected: BUILD SUCCEEDED, 0 failures.
- [ ] **Step 5:** Commit: `fix: read the cloudflared log incrementally off the main thread`.

### Task 10: Move the cloudflared process spawns off main

`killOrphanedCloudflared()` spawns `/usr/bin/pgrep` and reads to EOF (`CloudflareTunnel.swift:361-372`), and `start(localPort:)` `Process.run()`s the 38 MB cloudflared binary (`CloudflareTunnel.swift:226-251`). Both are `@MainActor`. Reached from `applyNetworkMode` (`QuipMacApp.swift:772`), the 60 s health timer (`CloudflareTunnel.swift:265-273`), the termination auto-restart (`:238`), and `restart()` (`:160`).

**Files:**
- Modify: `QuipMac/Services/CloudflareTunnel.swift:160-273`, `:361-372`

- [ ] **Step 1:** Make `killOrphanedCloudflared()` and the `Process.run()` in `start(localPort:)` `nonisolated`, invoked from a serial utility queue owned by the service; publish state changes back on main.
- [ ] **Step 2:** Guard against overlapping starts — a `start()` issued while one is in flight must be dropped, not queued.
- [ ] **Step 3:** Build + full suite. Expected: BUILD SUCCEEDED, 0 failures.
- [ ] **Step 4:** Commit: `fix: spawn cloudflared and pgrep off the main thread`.

### Noted, not scheduled

Found by the same sweep, lower exposure — recorded so they are not rediscovered from scratch:

- `WhisperDictationService.ingest(_:)` (`:66`) — base64 PCM decode + `queue.sync` on main, once per PTT audio chunk (`QuipMacApp.swift:1969`).
- `PINStore.read()` (`:110`) — synchronous `SecItemCopyMatching` during `App.init` on main. The file's own comment at `:88-92` already records a sampled hang on this exact stack.
- `ImageUploadHandler.save(message:)` (`:97`, `:129`) — full base64 decode + atomic disk write of an arbitrarily large image on main (`QuipMacApp.swift:1454`).
- `PromptLibrary.rescan()` (`:224-252`) and `VibeCutPromptReader.read()` (`:70`, `:91`) — serial whole-directory file reads on main.
- `WebSocketServer.broadcast<T>` (`:631`) — `JSONEncoder().encode` on main for payloads up to 4 MiB (`TTSAudioMessage`, screenshot `TerminalContentMessage`, `DiagnosticsBundleMessage`).
- `QuipMacApp.windowIndexForWindow(_:terminalApp:)` (`:3275-3313`) — AX title walk with no callers; dead code, same defect as Task 5.

---

## Verification

After all tasks, confirm the fix against the real failure — the hang reports, not just the tests.

- [ ] **Full suite green**

```bash
cd QuipMac && xcodegen generate && \
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: ≥636 tests, 0 failures.

- [ ] **No new hang reports under load**

Reinstalling the Mac app costs the user their Accessibility and Screen Recording TCC grants, so this step is the user's call, not an automatic one. When they do install and run the new build, watch for new reports:

```bash
ls -lt /Library/Logs/DiagnosticReports/ | grep -i quip | head
```

Baseline to beat: 4 hang reports and 3 `cpu_resource.diag` reports between 2026-07-27 and 2026-08-01. Exercise the path that produced them — a Claude Code session spawning many short-lived children in a tracked terminal window, with the Settings General tab open — and confirm no new `Quip_*.hang` appears.

- [ ] **Working tree clean of generated churn**

```bash
git status --short
```

Expected: empty. In particular `QuipMac/QuipMac.xcodeproj/project.pbxproj` must not appear — if it does, `git checkout` it.
