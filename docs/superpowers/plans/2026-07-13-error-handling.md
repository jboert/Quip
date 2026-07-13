# Error Handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Quip's failures legible — benign events stop logging as failures, real failures reach the phone with a cause, and no swallowed error can hide breakage.

**Architecture:** A small severity+subsystem logging facility (`QuipLog`) becomes the single reporting path. The WebSocket connection-state logging is reclassified through a pure function so a probe closing normally can never be printed as `Connection FAILED`. The phone gets a deadline contract generalized from the existing image-upload watchdog. Finally a mechanical triage sweep classifies every `try?` / `guard-else` site and fixes the real swallows.

**Tech Stack:** Swift 6 (strict concurrency), XCTest, xcodegen, Network.framework (`NWConnection`), SwiftUI.

## Global Constraints

- Peers: **QuipMac + QuipiOS only.** Never touch QuipLinux / QuipAndroid.
- Swift 6 strict concurrency: `xcodebuild` is the only isolation oracle. SourceKit under-reports actor-isolation errors — always build before claiming compile.
- Mac tests: run **signed**, and **quit Quip first** (the test host binds 8765). Always pass `-skip-testing:QuipMacTests/APNsJWTTests` — it blocks the suite on a Keychain prompt (`APNsKeyStore.swift:62`), observed hanging 57 minutes.
- `xcodegen generate` before any build (new files aren't in the committed pbxproj); restore `project.pbxproj` before committing.
- Log paths come from `LogPaths` only — never hardcode `~/Library/Logs/Quip`.
- Never commit physical device names.

---

### Task 1: `QuipLog` — severity + subsystem facility

**Files:**
- Create: `QuipMac/Services/QuipLog.swift`
- Test: `QuipMac/Tests/QuipLogTests.swift`

**Interfaces:**
- Consumes: `LogPaths.webSocketPath` (existing).
- Produces: `QuipLog.Severity` (`.info` / `.warn` / `.error`), `QuipLog.line(severity:subsystem:message:)` (pure formatter, returns `String`), `QuipLog.write(severity:subsystem:message:to:)` (appends to a path). Tasks 2 and 3 call these.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Quip

final class QuipLogTests: XCTestCase {

    func test_line_tagsSeverityAndSubsystem() {
        let line = QuipLog.line(severity: .error, subsystem: "ws", message: "socket died")
        XCTAssertTrue(line.contains("[ERROR]"), "severity must be greppable: \(line)")
        XCTAssertTrue(line.contains("[ws]"), "subsystem must be greppable: \(line)")
        XCTAssertTrue(line.contains("socket died"))
        XCTAssertTrue(line.hasSuffix("\n"), "log lines must be newline-terminated")
    }

    func test_line_infoAndWarnAreDistinguishable() {
        let info = QuipLog.line(severity: .info, subsystem: "ws", message: "probe closed")
        let warn = QuipLog.line(severity: .warn, subsystem: "ws", message: "retrying")
        XCTAssertTrue(info.contains("[INFO]"))
        XCTAssertTrue(warn.contains("[WARN]"))
        XCTAssertFalse(info.contains("[ERROR]"), "a benign event must never read as an error")
    }

    func test_write_appendsAndCreatesFile() throws {
        let tmp = NSTemporaryDirectory() + "quiplog-test-\(UUID().uuidString).log"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        QuipLog.write(severity: .info, subsystem: "test", message: "first", to: tmp)
        QuipLog.write(severity: .error, subsystem: "test", message: "second", to: tmp)
        let contents = try String(contentsOfFile: tmp, encoding: .utf8)
        XCTAssertTrue(contents.contains("first"))
        XCTAssertTrue(contents.contains("second"))
        XCTAssertEqual(contents.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd QuipMac && xcodegen generate
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS' \
  -only-testing:QuipMacTests/QuipLogTests 2>&1 | grep -E "error:|\*\* TEST"
```
Expected: FAIL — `cannot find 'QuipLog' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The single reporting path for Quip's diagnostic logs.
///
/// Before this existed, every site invented its own `print`, and — worse —
/// benign events were written with the same alarming wording as real failures.
/// A `LatencyProbeService` TCP probe closing normally logged `Connection
/// FAILED: reset by peer` once a minute, which sent a debugging session chasing
/// a dual-backend deadlock that did not exist. Severity is what makes a log
/// readable: `[INFO]` is "this happened", `[ERROR]` is "this broke".
enum QuipLog {

    enum Severity: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    /// Pure formatter — kept separate from the file write so it can be tested
    /// without touching the disk.
    static func line(severity: Severity, subsystem: String, message: String) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
        return "[\(ts)] [\(severity.rawValue)] [\(subsystem)] \(message)\n"
    }

    /// Append one line to `path`, creating the file if it doesn't exist.
    /// Write failures are swallowed on purpose: a logger that crashes the app
    /// on a disk-full event isn't doing its job.
    static func write(severity: Severity, subsystem: String, message: String, to path: String) {
        let text = line(severity: severity, subsystem: subsystem, message: message)
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(text.utf8))
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS' \
  -only-testing:QuipMacTests/QuipLogTests 2>&1 | grep -E "\*\* TEST|Executed"
```
Expected: `** TEST SUCCEEDED **`, 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git checkout -- QuipMac/QuipMac.xcodeproj/project.pbxproj
git add QuipMac/Services/QuipLog.swift QuipMac/Tests/QuipLogTests.swift
git commit -m "feat(mac): QuipLog — severity + subsystem so benign events stop reading as failures"
```

---

### Task 2: Stop logging benign probes as failures

The bug this fixes: `LatencyProbeService` opens a TCP-only probe to each alternate URL every 60s. It never sends a WebSocket handshake and closes when superseded. `websocket.log` printed `Connection FAILED: POSIXErrorCode(rawValue: 54): Connection reset by peer` for each one.

**Files:**
- Create: `QuipMac/Services/ConnectionOutcome.swift`
- Modify: `QuipMac/Services/WebSocketServer.swift:345-426` (the `handleNewConnection` state handler)
- Test: `QuipMac/Tests/ConnectionOutcomeTests.swift`

**Interfaces:**
- Consumes: `QuipLog.Severity` (Task 1).
- Produces: `ConnectionOutcome.classify(reachedReady:error:) -> ConnectionOutcome`, with cases `.abortedHandshake`, `.closedNormally`, `.failed`, each exposing `.severity` and `.describe(endpoint:)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Quip

final class ConnectionOutcomeTests: XCTestCase {

    /// The exact shape of a LatencyProbeService probe: TCP connects, the WS
    /// handshake never completes (never reaches .ready), then the peer closes.
    /// This MUST NOT be reported as a failure — doing so cost a full debugging
    /// session chasing a dual-backend bug that did not exist.
    func test_probeThatNeverHandshook_isBenign_notAFailure() {
        let outcome = ConnectionOutcome.classify(reachedReady: false, error: "reset by peer")
        XCTAssertEqual(outcome, .abortedHandshake)
        XCTAssertEqual(outcome.severity, .info)
        XCTAssertFalse(outcome.describe(endpoint: "192.168.4.34:56767").uppercased().contains("FAILED"))
    }

    /// A socket that DID complete the handshake and then broke is a real error.
    func test_establishedSocketThatDies_isAFailure() {
        let outcome = ConnectionOutcome.classify(reachedReady: true, error: "reset by peer")
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(outcome.severity, .error)
        XCTAssertTrue(outcome.describe(endpoint: "100.72.13.19:56736").contains("reset by peer"))
    }

    /// A clean close of an established socket is normal, not an error.
    func test_establishedSocketClosedCleanly_isBenign() {
        let outcome = ConnectionOutcome.classify(reachedReady: true, error: nil)
        XCTAssertEqual(outcome, .closedNormally)
        XCTAssertEqual(outcome.severity, .info)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd QuipMac && xcodegen generate
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS' \
  -only-testing:QuipMacTests/ConnectionOutcomeTests 2>&1 | grep -E "error:|\*\* TEST"
```
Expected: FAIL — `cannot find 'ConnectionOutcome' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Why a connection ended — and, crucially, whether that is worth alarming
/// about.
///
/// `LatencyProbeService` on the phone opens a TCP-only probe to each alternate
/// URL every 60 seconds. It never performs a WebSocket handshake and closes
/// when the next probe supersedes it. That is *routine*, but the old code
/// printed it as `Connection FAILED: reset by peer`, indistinguishable from a
/// real socket dying. The discriminator is simple: did the connection ever
/// reach `.ready` (i.e. complete the handshake)?
enum ConnectionOutcome: Equatable {
    /// Closed before the handshake completed — a probe, a port scan, or a
    /// client that changed its mind. Benign.
    case abortedHandshake
    /// An established connection that closed cleanly.
    case closedNormally
    /// An established connection that broke. The only real failure.
    case failed(String)

    static func classify(reachedReady: Bool, error: String?) -> ConnectionOutcome {
        guard reachedReady else { return .abortedHandshake }
        guard let error else { return .closedNormally }
        return .failed(error)
    }

    var severity: QuipLog.Severity {
        switch self {
        case .abortedHandshake, .closedNormally: return .info
        case .failed: return .error
        }
    }

    func describe(endpoint: String) -> String {
        switch self {
        case .abortedHandshake:
            return "connection from \(endpoint) closed before handshake (probe or abandoned dial)"
        case .closedNormally:
            return "connection from \(endpoint) closed"
        case .failed(let error):
            return "established connection from \(endpoint) failed: \(error)"
        }
    }
}
```

Note the associated value: `classify` returns `.failed("reset by peer")`, and `Equatable` makes `XCTAssertEqual(outcome, .failed)` in Step 1 a compile error. Fix the test to `XCTAssertEqual(outcome, .failed("reset by peer"))` before running.

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS' \
  -only-testing:QuipMacTests/ConnectionOutcomeTests 2>&1 | grep -E "\*\* TEST|Executed"
```
Expected: `** TEST SUCCEEDED **`, 3 tests, 0 failures.

- [ ] **Step 5: Wire it into `WebSocketServer`**

In `handleNewConnection` (`QuipMac/Services/WebSocketServer.swift:345`), track whether the connection ever reached `.ready`, and route `.failed` / `.cancelled` through `ConnectionOutcome`. Replace the state handler's logging:

```swift
    private nonisolated func handleNewConnection(_ connection: NWConnection) {
        Self.wslog("newConnectionHandler fired for \(connection.endpoint)")
        // Did this connection ever complete the WS handshake? A probe never
        // does — and a probe closing is not a failure. Class instance so the
        // @Sendable state closure can flip it without capturing a mutable var.
        let handshake = HandshakeFlag()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                handshake.reachedReady = true
                // ... existing .ready body unchanged ...
            case .failed(let error):
                let outcome = ConnectionOutcome.classify(
                    reachedReady: handshake.reachedReady,
                    error: String(describing: error))
                Self.wslog(outcome.describe(endpoint: String(describing: connection.endpoint)),
                           severity: outcome.severity)
                let remoteStr = String(describing: connection.endpoint)
                DispatchQueue.main.async {
                    self.connectionLog?.record(.failed, remote: remoteStr, detail: String(describing: error))
                    self.removeConnection(connection)
                }
            case .cancelled:
                let outcome = ConnectionOutcome.classify(
                    reachedReady: handshake.reachedReady, error: nil)
                Self.wslog(outcome.describe(endpoint: String(describing: connection.endpoint)),
                           severity: outcome.severity)
                let remoteStr = String(describing: connection.endpoint)
                DispatchQueue.main.async {
                    self.connectionLog?.record(.disconnected, remote: remoteStr, detail: nil)
                    self.removeConnection(connection)
                }
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
        Self.wslog("connection.start() called immediately")
    }
```

Add the flag type and the severity-aware `wslog` overload in the same file:

```swift
    /// One-bit box so the @Sendable state closure can record "handshake done"
    /// without Swift 6 rejecting a captured mutable local (`sending 'x' risks
    /// causing data races`). Accessed only from the network queue.
    private final class HandshakeFlag: @unchecked Sendable {
        var reachedReady = false
    }

    private nonisolated static func wslog(_ msg: String, severity: QuipLog.Severity = .info) {
        QuipLog.write(severity: severity, subsystem: "ws", message: msg, to: LogPaths.webSocketPath)
        print("[WebSocketServer] \(msg)")
    }
```

Delete the now-unconditional `Self.wslog("Connection state: \(state) ...")` line at `:349` — it printed raw `failed(POSIXErrorCode...)` for every probe and is the other half of the noise.

- [ ] **Step 6: Fix the "pending auth" lie and add a client-live line**

At `:352` the code logs `Connection ready (pending auth)` even when `requireAuth` is false and the client is authenticated on the spot. Log the state the code is actually in. In the `.ready` branch, replace that line and add the success marker after the auth signal is sent (`:380`):

```swift
            case .ready:
                handshake.reachedReady = true
                let requireAuthNow = self.requireAuth
                Self.wslog(requireAuthNow
                    ? "connection ready from \(connection.endpoint) — awaiting PIN"
                    : "connection ready from \(connection.endpoint) — authenticated (no PIN required)")
```

and after `self.receiveMessage(on: connection)`:

```swift
                Self.wslog("client live: \(connection.endpoint) (auth=\(requireAuthNow ? "pin" : "none"))")
```

`requireAuthNow` is already computed in this branch at `:359` — move that `let` above the new log line and delete the duplicate.

- [ ] **Step 7: Build and run the full suite**

```bash
pkill -x Quip
cd QuipMac && xcodegen generate
xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS' \
  -skip-testing:QuipMacTests/APNsJWTTests 2>&1 | grep -E "\*\* TEST|Executed .* tests"
```
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 8: Verify against the real thing**

Install the build, leave the phone connected for 3 minutes (long enough for 3 latency probes), then:

```bash
grep -c "ERROR" ~/Library/Logs/Quip/websocket.log   # probes must NOT appear here
grep "closed before handshake" ~/Library/Logs/Quip/websocket.log | tail -3
```
Expected: the 60-second probes appear as `[INFO] … closed before handshake`, and no `[ERROR]` line is produced while the connection is healthy.

- [ ] **Step 9: Commit**

```bash
git checkout -- QuipMac/QuipMac.xcodeproj/project.pbxproj
git add QuipMac/Services/ConnectionOutcome.swift QuipMac/Tests/ConnectionOutcomeTests.swift QuipMac/Services/WebSocketServer.swift
git commit -m "fix(mac): benign probes no longer log as Connection FAILED"
```

---

### Task 3: Stop claiming "delivered" when we only know "injected"

`QuipMacApp.swift:1429` prints `image_upload: delivered`. It means the AppleScript returned without error. It does **not** mean the target app consumed the image — during a real investigation this made a working upload indistinguishable from a broken one.

**Files:**
- Modify: `QuipMac/QuipMacApp.swift:1429-1431` (success branch), `:1434` (failure branch)

**Interfaces:**
- Consumes: `QuipLog` (Task 1). Produces: nothing new.

- [ ] **Step 1: Change the wording to what the code actually knows**

```swift
                        if result.success {
                            // "injected", not "delivered": AppleScript returned
                            // without error, which tells us the keystroke/paste
                            // was dispatched — NOT that the target app consumed
                            // it. Claiming delivery here once made a working
                            // upload indistinguishable from a broken one.
                            print("[Quip] image_upload: injected into windowId=\(msg.windowId) cli=\(cliKind.rawValue) (app consumption unconfirmed)")
                            appendImageUploadDiagnostic("injected id=\(uploadId) route=\(route) cli=\(cliKind.rawValue) cached_cli=\(cachedCliKind.rawValue) term=\(termApp.rawValue) inject_ms=\(injectMs) total_ms=\(totalMs) self_heal=\(selfHealed ? 1 : 0)")
                            self.webSocketServer.broadcast(ImageUploadAckMessage(imageId: msg.imageId, savedPath: savedURL.path))
                        } else {
```

- [ ] **Step 2: Build**

```bash
cd QuipMac && xcodegen generate
xcodebuild -project QuipMac.xcodeproj -scheme QuipMac -configuration Release \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error: |\*\* BUILD"
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git checkout -- QuipMac/QuipMac.xcodeproj/project.pbxproj
git add QuipMac/QuipMacApp.swift
git commit -m "fix(mac): image_upload logs 'injected', not 'delivered' — we don't know the app consumed it"
```

---

### Task 4: Deadline contract — nothing spins forever

The phone's image upload already has this shape: a 10s watchdog, breadcrumb stages, and `ImageUploadFailure` mapping a raw reason to a labelled chip plus a one-word CTA (`PendingImageState.swift:10-78`). Generalize it so every in-flight action resolves.

**Files:**
- Create: `QuipiOS/Services/InFlightAction.swift`
- Test: `QuipiOS/Tests/InFlightActionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `InFlightAction<E>` with `start(deadline:)`, `resolve(.succeeded)`, `resolve(.failed(E))`, `tick(now:) -> Bool`, and `state` (`.idle` / `.inFlight` / `.succeeded` / `.failed(cause:nextStep:)`). Later phone work consumes this.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Quip

final class InFlightActionTests: XCTestCase {

    func test_startedAction_isInFlight() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        XCTAssertEqual(action.state, .inFlight)
    }

    /// The whole point: an action that never hears back MUST resolve to a
    /// failure with a cause and a next step. It must never sit in .inFlight
    /// forever — that is the spinner-that-never-clears bug.
    func test_actionPastDeadline_resolvesToFailureWithCauseAndNextStep() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        let tripped = action.tick(now: 11)
        XCTAssertTrue(tripped, "the watchdog must trip once past the deadline")
        guard case .failed(let cause, let nextStep) = action.state else {
            return XCTFail("expected .failed, got \(action.state)")
        }
        XCTAssertFalse(cause.isEmpty, "a failure must say what went wrong")
        XCTAssertFalse(nextStep.isEmpty, "a failure must say what to do about it")
    }

    func test_actionBeforeDeadline_staysInFlight() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        XCTAssertFalse(action.tick(now: 9))
        XCTAssertEqual(action.state, .inFlight)
    }

    /// A late reply after the watchdog already tripped must not resurrect the
    /// action — the user has been told it failed.
    func test_lateSuccessAfterTimeout_doesNotResurrect() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        _ = action.tick(now: 11)
        action.resolve(.succeeded)
        guard case .failed = action.state else {
            return XCTFail("a timed-out action must stay failed, got \(action.state)")
        }
    }

    func test_successBeforeDeadline_succeeds() {
        var action = InFlightAction(deadline: 10)
        action.start(at: 0)
        action.resolve(.succeeded)
        XCTAssertEqual(action.state, .succeeded)
        XCTAssertFalse(action.tick(now: 99), "a resolved action's watchdog is a no-op")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd QuipiOS && xcodegen generate
xcodebuild test -project QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,id=9A204976-5E83-4909-B88C-7C06D3FD69B2' \
  -only-testing:QuipiOSTests/InFlightActionTests 2>&1 | grep -E "error:|\*\* TEST"
```
Expected: FAIL — `cannot find 'InFlightAction' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// An action awaiting a reply from the Mac, with a deadline it cannot outlive.
///
/// The failure this prevents: a thumbnail spinner that never clears. Every
/// in-flight action must end somewhere — success, or a failure that says what
/// went wrong and what to do next. "Still spinning" is not a terminal state,
/// and a user staring at one has no way to tell a slow Mac from a dead socket.
///
/// Time is injected (`at:` / `now:`) rather than read from the clock so the
/// state machine is testable without waiting real seconds.
struct InFlightAction: Equatable {

    enum State: Equatable {
        case idle
        case inFlight
        case succeeded
        /// Always carries BOTH: what went wrong, and the one thing to do next.
        case failed(cause: String, nextStep: String)
    }

    enum Resolution: Equatable {
        case succeeded
        case failed(cause: String, nextStep: String)
    }

    private(set) var state: State = .idle
    private let deadline: TimeInterval
    private var startedAt: TimeInterval?

    init(deadline: TimeInterval) {
        self.deadline = deadline
    }

    mutating func start(at now: TimeInterval) {
        state = .inFlight
        startedAt = now
    }

    /// Resolve from a reply. A no-op once the action already reached a terminal
    /// state — a late ack must not resurrect an action the user was already
    /// told had failed.
    mutating func resolve(_ resolution: Resolution) {
        guard state == .inFlight else { return }
        switch resolution {
        case .succeeded:
            state = .succeeded
        case .failed(let cause, let nextStep):
            state = .failed(cause: cause, nextStep: nextStep)
        }
        startedAt = nil
    }

    /// Drive the watchdog. Returns true on the tick that trips it.
    mutating func tick(now: TimeInterval) -> Bool {
        guard state == .inFlight, let startedAt else { return false }
        guard now - startedAt >= deadline else { return false }
        state = .failed(cause: "Mac didn't respond in \(Int(deadline))s",
                        nextStep: "Check the connection and try again")
        self.startedAt = nil
        return true
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -project QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,id=9A204976-5E83-4909-B88C-7C06D3FD69B2' \
  -only-testing:QuipiOSTests/InFlightActionTests 2>&1 | grep -E "\*\* TEST|Executed"
```
Expected: `** TEST SUCCEEDED **`, 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git checkout -- QuipiOS/QuipiOS.xcodeproj/project.pbxproj
git add QuipiOS/Services/InFlightAction.swift QuipiOS/Tests/InFlightActionTests.swift
git commit -m "feat(ios): InFlightAction — deadline contract so no action can spin forever"
```

---

### Task 5: Adopt the deadline in the phone's unacked actions

**Files:**
- Modify: `QuipiOS/QuipApp.swift` (the send-text / keystroke / prompt-tap send paths)
- Test: `QuipiOS/Tests/InFlightActionTests.swift` (extend)

**Interfaces:**
- Consumes: `InFlightAction` (Task 4).

- [ ] **Step 1: Find every action that awaits a Mac reply without a deadline**

```bash
grep -n "send(\|sendMessage(\|client.send" QuipiOS/QuipApp.swift | head -40
```
For each hit, determine whether the UI enters a waiting state (spinner, disabled button, "sending…") and whether anything guarantees that state ends. Record the list — those with no guarantee are the ones to fix. The image-upload path already has its watchdog and is the reference, not a target.

- [ ] **Step 2: Write a failing test per unguarded action found**

For each, assert the same contract as Task 4: entering the waiting state and never hearing back must resolve to `.failed` with a non-empty cause and next step. Reuse the shape of `test_actionPastDeadline_resolvesToFailureWithCauseAndNextStep`.

- [ ] **Step 3: Adopt `InFlightAction` at each site, run tests, commit**

```bash
xcodebuild test -project QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,id=9A204976-5E83-4909-B88C-7C06D3FD69B2' \
  -only-testing:QuipiOSTests/InFlightActionTests 2>&1 | grep -E "\*\* TEST|Executed"
git commit -m "fix(ios): unacked actions resolve to a failure instead of spinning"
```

---

### Task 6: The triage sweep

~540 sites: 149 `try?`, 324 `else { return }`, 68 `else { return nil }`, 0 empty `catch`. **Most are legitimate control flow.** Blanket-logging all of them would bury the real signals under new noise — the exact disease being cured. Classify, then fix only the real swallows.

**Files:**
- Create: `docs/superpowers/plans/2026-07-13-swallowed-errors-audit.md` (the accounting)
- Modify: whichever files hold real swallows

- [ ] **Step 1: Enumerate every site mechanically**

```bash
cd /Users/erickbzovi/Projects/Quip
{
  grep -rn "try?" --include="*.swift" QuipMac QuipiOS | grep -v "/Tests/"
  grep -rn "else { return }" --include="*.swift" QuipMac QuipiOS | grep -v "/Tests/"
  grep -rn "else { return nil }" --include="*.swift" QuipMac QuipiOS | grep -v "/Tests/"
} | sort > /tmp/quip-swallow-sites.txt
wc -l /tmp/quip-swallow-sites.txt
```

- [ ] **Step 2: Classify each site**

Two buckets, and the rule is mechanical:
- **Real swallow** — an error value or failure path is discarded: `try?` that drops a thrown error the caller could act on; a `guard` whose else-branch returns on an unexpected/failed condition without reporting it (a nil socket, a missing window, a failed decode).
- **Benign control flow** — an optional unwrap where nil is an ordinary expected value, an early return on an empty collection, a cache miss.

Write every site into the audit doc under its bucket, with a one-line reason. **Do not truncate the list** — an unlisted site reads as "covered" when it wasn't. If the list is long, that is the finding.

- [ ] **Step 3: Fix the real swallows, in batches by subsystem**

Route each through `QuipLog` (Mac) or the phone's existing failure surfacing. One commit per subsystem so a regression can be bisected to a single area. After each batch:

```bash
pkill -x Quip
cd QuipMac && xcodegen generate && xcodebuild test -project QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' -skip-testing:QuipMacTests/APNsJWTTests 2>&1 | grep -E "\*\* TEST|Executed .* tests"
```
Expected: `** TEST SUCCEEDED **` after every batch. A batch that breaks a test does not get committed.

- [ ] **Step 4: Commit the accounting**

```bash
git add docs/superpowers/plans/2026-07-13-swallowed-errors-audit.md
git commit -m "docs: swallowed-error audit — every try?/guard-else site classified"
```

---

## Self-review

**Spec coverage:** §1 facility → Task 1. §2 logs that lie: probes → Task 2, pending-auth wording + client-live line → Task 2 Step 6, image_upload "delivered" → Task 3. §3 never spin forever → Tasks 4 and 5. §4 triage sweep → Task 6. Testing requirements (pure functions, signed Mac runs, skip `APNsJWTTests`) → Global Constraints and each task's run commands. No spec section is unimplemented.

**Deferred, as the spec states:** `pasteImage`'s missing Terminal.app fallback and the TIFF-only clipboard are wishlist items, not tasks here.

**Known sharp edge:** Task 2 Step 3's `ConnectionOutcome.failed` carries an associated value, so the Step 1 test's `XCTAssertEqual(outcome, .failed)` will not compile until it is changed to `.failed("reset by peer")`. This is called out inline in Step 3 rather than hidden.
