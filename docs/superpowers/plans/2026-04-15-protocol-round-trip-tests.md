# MessageProtocol Round-Trip Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add cross-platform round-trip tests for every message type in `Shared/MessageProtocol.swift`, close the coverage gap for the 4 untested message types (`DuplicateWindowMessage`, `CloseWindowMessage`, `OutputDeltaMessage`, `TTSAudioMessage`), add `WindowState` backward-compat tests, and introduce a `QuipMacTests` target so protocol tests run on every Mac build.

**Architecture:** Move the existing `QuipiOS/Tests/MessageProtocolTests.swift` to `Shared/Tests/MessageProtocolTests.swift` with a conditional `@testable import` block that works under both iOS and macOS test targets. Add `QuipMacTests` to `QuipMac/project.yml` alongside the existing `QuipMac` app target. Fix the pre-existing duplicate-compilation wart in `QuipiOS/project.yml` (test target currently compiles Shared twice) as a standalone preceding commit. All work lands as 3 focused commits on `eb-branch`.

**Tech Stack:** Swift 6, XCTest, XcodeGen (`project.yml`), `xcodebuild test`, JSON encoding via the existing `MessageCoder` helper.

**Spec:** `docs/superpowers/specs/2026-04-15-protocol-round-trip-tests-design.md`

**Worktree note:** Plan is small enough (3 commits, all scoped to test code and build config) that a dedicated worktree is not necessary. Execute directly on `eb-branch`.

**Do NOT push.** Per `eb-branch` push policy in the user's memory, commits stay local unless the user explicitly confirms a push.

---

## Task 1: Pre-flight state verification

**Purpose:** Confirm the working tree is clean, all required tools are installed, and at least one iOS simulator is available before making any changes. This is a safety gate — if any precondition fails, the plan pauses before touching files.

**Files:**
- Read-only inspection only

- [ ] **Step 1.1: Verify working tree is clean**

Run:
```bash
git status
```

Expected: `nothing to commit, working tree clean`. If not clean, stop and clean up first.

- [ ] **Step 1.2: Verify xcodegen is installed**

Run:
```bash
which xcodegen && xcodegen --version
```

Expected: a path (probably `/opt/homebrew/bin/xcodegen` or `/usr/local/bin/xcodegen`) and a version number. If not installed, stop and report BLOCKED — install via `brew install xcodegen` and restart this plan.

- [ ] **Step 1.3: Verify xcodebuild is available**

Run:
```bash
xcodebuild -version
```

Expected: `Xcode 16.x` or later on its own line, followed by a build number line. If `xcodebuild` is not found, Xcode Command Line Tools are missing — stop and report BLOCKED.

- [ ] **Step 1.4: Find an available iOS simulator name**

Run:
```bash
xcrun simctl list devices available | grep "iPhone" | head -5
```

Expected: one or more lines listing iPhone simulator names and their state. Pick the first `iPhone 1X ...` entry (typically `iPhone 15`, `iPhone 16`, etc.) and **note its exact name** — this name will be used in every `xcodebuild test` command for the iOS target throughout the plan. If no iPhones are listed, stop and report BLOCKED (install a simulator via Xcode → Settings → Platforms).

For the rest of this plan, replace `<IOS_SIM_NAME>` with the simulator name you noted in this step.

- [ ] **Step 1.5: Verify QuipMacTests bundle identifier is not already in use**

Run:
```bash
grep -r "com.quip.QuipMacTests" .
```

Expected: empty output (the identifier is not currently in use anywhere in the repo). If any match is found, stop and report the conflict — a different identifier must be chosen before Task 5.

- [ ] **Step 1.6: Confirm base SHA**

Run:
```bash
git rev-parse HEAD
```

Expected: a 40-character SHA. Record this as `BASE_SHA` — you will reference it later during verification.

---

## Task 2: Commit 1 — Fix QuipiOS duplicate compilation

**Purpose:** Remove the redundant `- path: ../Shared` entry from `QuipiOSTests.sources` in `QuipiOS/project.yml`. The app target already compiles `Shared/` via its own `sources` list, and `@testable import QuipiOS` gives the test target access to those types through the module boundary. Having the test target also compile `Shared/` on its own creates two parallel copies of every `MessageProtocol` type in different modules — wasteful and slightly misleading.

**Files:**
- Modify: `QuipiOS/project.yml`
- Regenerate: `QuipiOS/QuipiOS.xcodeproj/project.pbxproj`

- [ ] **Step 2.1: Edit QuipiOS/project.yml (explicit find-and-replace)**

Use the Edit tool with this exact find-and-replace in `QuipiOS/project.yml`:

**Find** (exactly this block — 7 lines):

```yaml
  QuipiOSTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests
      - path: ../Shared
    dependencies:
```

**Replace with** (6 lines — the `- path: ../Shared` line is removed):

```yaml
  QuipiOSTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests
    dependencies:
```

This leaves the `dependencies: - target: QuipiOS` line and everything after it unchanged.

- [ ] **Step 2.2: Verify the edit took effect**

Run:
```bash
grep -A 6 "QuipiOSTests:" QuipiOS/project.yml
```

Expected output: the new 6-line block above, with `- path: Tests` as the only source entry. Verify `../Shared` is NOT present in the sources list.

- [ ] **Step 2.3: Regenerate the QuipiOS Xcode project**

Run:
```bash
cd QuipiOS && xcodegen generate && cd ..
```

Expected: xcodegen prints its progress lines and exits 0. No errors.

- [ ] **Step 2.4: Run the QuipiOS test target with existing tests**

Run (replace `<IOS_SIM_NAME>` with the simulator name from Step 1.4):
```bash
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination "platform=iOS Simulator,name=<IOS_SIM_NAME>" \
  2>&1 | tail -40
```

Expected: the final lines should include `** TEST SUCCEEDED **`. All existing tests (both `MessageProtocolTests` and `PTTStressTests`) must still pass. This commit adds NO new test logic — a green run proves the structural simplification (relying on `@testable import QuipiOS` for access to `MessageProtocol` types) still resolves correctly.

**If any test fails:** STOP. The failing test is telling you something about what the duplicate compilation was hiding. Report the failure to the controller and do NOT commit. Do not proceed to Task 3.

- [ ] **Step 2.5: Stage the changes**

Run:
```bash
git add QuipiOS/project.yml QuipiOS/QuipiOS.xcodeproj/project.pbxproj
```

- [ ] **Step 2.6: Review the staged diff**

Run:
```bash
git diff --cached --stat
```

Expected: exactly two files listed — `QuipiOS/project.yml` with a small deletion, and `QuipiOS/QuipiOS.xcodeproj/project.pbxproj` with whatever xcodegen emitted. The project.yml diff should be 1–3 lines removed (the `- path: ../Shared` entry and possibly some blank-line shuffling), nothing added. The pbxproj diff may be larger due to xcodegen serialization noise.

If `git status` shows other files (especially `Info.plist` — which shouldn't appear because it was gitignored in `#14`), STOP and investigate. Extraneous changes mean something unexpected happened.

- [ ] **Step 2.7: Create Commit 1**

Run:
```bash
git commit -m "$(cat <<'EOF'
Quit compilin' the protocol file into the iPhone test target twice, once through the app and once through the Shared path. Only needed it once, so I told it to pick the one that comes in through @testable and leave the other alone.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds. Output shows `2 files changed` (or 1 file if xcodegen's pbxproj output happened to be identical, which is unlikely but benign).

- [ ] **Step 2.8: Confirm commit landed**

Run:
```bash
git log -1 --stat
```

Expected: commit message matches what you passed, and the stat shows at most `QuipiOS/project.yml` and `QuipiOS/QuipiOS.xcodeproj/project.pbxproj`.

---

## Task 3: Move MessageProtocolTests.swift to Shared/Tests/

**Purpose:** Physically move the test file to `Shared/Tests/`, and add the conditional `@testable import` block at the top so the same file can compile under either `QuipiOSTests` or `QuipMacTests`.

**Files:**
- Create: `Shared/Tests/MessageProtocolTests.swift`
- Delete: `QuipiOS/Tests/MessageProtocolTests.swift`

- [ ] **Step 3.1: Create the Shared/Tests directory**

Run:
```bash
mkdir -p Shared/Tests
```

Expected: directory is created silently if it didn't exist. No error.

- [ ] **Step 3.2: Move the file**

Run:
```bash
git mv QuipiOS/Tests/MessageProtocolTests.swift Shared/Tests/MessageProtocolTests.swift
```

Expected: git stages the move as a rename. No error. Using `git mv` instead of `mv` preserves git's rename detection and keeps blame history intact.

- [ ] **Step 3.3: Verify the move**

Run:
```bash
ls -la Shared/Tests/MessageProtocolTests.swift QuipiOS/Tests/MessageProtocolTests.swift 2>&1
```

Expected: the `Shared/Tests/` version exists, and the `QuipiOS/Tests/` version shows `No such file or directory`.

Run:
```bash
git status
```

Expected output contains:
```
Changes to be committed:
	renamed:    QuipiOS/Tests/MessageProtocolTests.swift -> Shared/Tests/MessageProtocolTests.swift
```

If git is showing `deleted:` for the old path and `new file:` for the new path instead of `renamed:`, that's fine — git's rename detection may still catch it at commit time based on content similarity. But `renamed:` is the cleaner state.

- [ ] **Step 3.4: Add the conditional @testable import block to the moved file**

Use the Edit tool with this exact find-and-replace in `Shared/Tests/MessageProtocolTests.swift`:

**Find** (the current first 2 lines of the file):

```swift
import XCTest
@testable import QuipiOS
```

**Replace with** (6 lines — `import XCTest` plus the conditional block):

```swift
import XCTest

#if canImport(QuipiOS)
@testable import QuipiOS
#elseif canImport(QuipMac)
@testable import QuipMac
#endif
```

This keeps the rest of the file (from the `/// Unit tests for...` doc comment onward) unchanged.

- [ ] **Step 3.5: Verify the import block is in place**

Run:
```bash
head -10 Shared/Tests/MessageProtocolTests.swift
```

Expected output should start with:
```swift
import XCTest

#if canImport(QuipiOS)
@testable import QuipiOS
#elseif canImport(QuipMac)
@testable import QuipMac
#endif

/// Unit tests for MessageProtocol encoding/decoding.
```

The `/// Unit tests for MessageProtocol encoding/decoding.` line marks the start of the original content that should be unchanged below the new import block.

Do NOT commit yet — Task 4 and Task 5 must run first so the project.yml changes can be part of the same commit (Commit 2 of the plan).

---

## Task 4: Update QuipiOS/project.yml to source new location

**Purpose:** Tell the `QuipiOSTests` target that its test sources now live in two places: its own `Tests/` directory (for `PTTStressTests.swift` which stays put) and `../Shared/Tests/` (for the moved `MessageProtocolTests.swift`).

**Files:**
- Modify: `QuipiOS/project.yml`

- [ ] **Step 4.1: Edit QuipiOS/project.yml (explicit find-and-replace)**

Note: this edits the block that was already modified by Task 2. The current state (after Task 2) has only `- path: Tests` in the `QuipiOSTests` sources. We are adding a second source path.

Use the Edit tool with this exact find-and-replace in `QuipiOS/project.yml`:

**Find** (exactly 6 lines — the state after Task 2):

```yaml
  QuipiOSTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests
    dependencies:
```

**Replace with** (7 lines — adds `- path: ../Shared/Tests`):

```yaml
  QuipiOSTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests
      - path: ../Shared/Tests
    dependencies:
```

- [ ] **Step 4.2: Verify the edit took effect**

Run:
```bash
grep -A 7 "QuipiOSTests:" QuipiOS/project.yml
```

Expected: both `- path: Tests` AND `- path: ../Shared/Tests` are present under the sources list, in that order. `../Shared` (without `/Tests`) should NOT be present.

---

## Task 5: Add QuipMacTests target to QuipMac/project.yml

**Purpose:** Create a new `bundle.unit-test` target on the Mac side that mirrors the iOS test target's shape but targets macOS and sources only the shared test directory.

**Files:**
- Modify: `QuipMac/project.yml`

- [ ] **Step 5.1: Read the current QuipMac/project.yml to find the insertion point**

Run:
```bash
cat QuipMac/project.yml
```

Expected: the file has a `targets:` section with one `QuipMac:` target defined. The target block ends at the last line of its `info.properties` section. The new `QuipMacTests` target should be added at the end of the `targets:` section.

- [ ] **Step 5.2: Append the QuipMacTests target block**

Use the Edit tool with this exact find-and-replace in `QuipMac/project.yml`. The `Find` string captures the last line of the existing `QuipMac` target's `info.properties` (which currently ends with `NSLocalNetworkUsageDescription`) — this is the unique anchor that identifies the end of the existing target.

**Find** (exactly this 3-line block — the last content of the existing QuipMac target):

```yaml
        NSBonjourServices:
          - _quip._tcp.
          - _quip._tcp
        NSLocalNetworkUsageDescription: Quip uses your local network to connect with the iPhone remote controller app.
```

**Replace with** (adds the new `QuipMacTests` target block after the existing content — note the indentation matches the sibling `QuipMac:` target exactly):

```yaml
        NSBonjourServices:
          - _quip._tcp.
          - _quip._tcp
        NSLocalNetworkUsageDescription: Quip uses your local network to connect with the iPhone remote controller app.
  QuipMacTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: ../Shared/Tests
    dependencies:
      - target: QuipMac
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.quip.QuipMacTests
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Quip.app/Contents/MacOS/Quip"
        BUNDLE_LOADER: "$(TEST_HOST)"
```

- [ ] **Step 5.3: Verify the QuipMacTests block is in place**

Run:
```bash
grep -A 13 "QuipMacTests:" QuipMac/project.yml
```

Expected: the full QuipMacTests block above, starting with `QuipMacTests:` and ending with the `BUNDLE_LOADER` line.

Run:
```bash
grep -c "^  Quip" QuipMac/project.yml
```

Expected: `2` — indicating exactly two top-level target entries (`QuipMac:` and `QuipMacTests:`) each at the 2-space indent level. If the output is `1`, the new target wasn't added. If it's `3` or more, something got duplicated.

---

## Task 6: Regenerate .xcodeproj files, verify both test targets, commit Commit 2

**Purpose:** Run `xcodegen` in both project directories to regenerate the `.xcodeproj` files, run the test suites on both targets with the existing tests (no new logic yet — this commit is pure structural move), and land Commit 2 once both sides are green.

**Files:**
- Regenerate: `QuipiOS/QuipiOS.xcodeproj/project.pbxproj`
- Regenerate: `QuipMac/QuipMac.xcodeproj/project.pbxproj` (adds the new QuipMacTests target structurally)

- [ ] **Step 6.1: Regenerate QuipiOS Xcode project**

Run:
```bash
cd QuipiOS && xcodegen generate && cd ..
```

Expected: xcodegen prints progress and exits 0. No errors.

- [ ] **Step 6.2: Regenerate QuipMac Xcode project**

Run:
```bash
cd QuipMac && xcodegen generate && cd ..
```

Expected: xcodegen prints progress and exits 0. The new `QuipMacTests` scheme should be mentioned in the output. No errors.

- [ ] **Step 6.3: Verify QuipMacTests scheme exists**

Run:
```bash
xcodebuild -list -project QuipMac/QuipMac.xcodeproj 2>&1 | grep -A 5 "Schemes:"
```

Expected output should include both `QuipMac` and `QuipMacTests` in the Schemes list.

If `QuipMacTests` is not present, xcodegen didn't pick up the new target — re-check Task 5 and re-run Step 6.2.

- [ ] **Step 6.4: Run QuipMacTests (the new target)**

Run:
```bash
xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMacTests \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | tail -60
```

Expected: `** TEST SUCCEEDED **` in the final lines. All the existing MessageProtocol tests should run under the Mac target and all should pass. The test count should match what was previously running in the iOS-only version (roughly 25 tests, depending on how many the existing file has).

**If any test fails:** STOP and investigate. The most likely cause is that a type in `MessageProtocol.swift` has access restrictions (e.g., `fileprivate` or missing) that hide it from the Mac-side `@testable import QuipMac`. Report the failure to the controller and do NOT proceed.

- [ ] **Step 6.5: Run QuipiOSTests (should still be green)**

Run (replace `<IOS_SIM_NAME>` with the simulator name from Step 1.4):
```bash
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination "platform=iOS Simulator,name=<IOS_SIM_NAME>" \
  2>&1 | tail -60
```

Expected: `** TEST SUCCEEDED **` in the final lines. Both `MessageProtocolTests` (now sourced from Shared) and `PTTStressTests` (still in QuipiOS/Tests/) should run and pass.

- [ ] **Step 6.6: Check git status before staging**

Run:
```bash
git status
```

Expected files to be staged or modified:
- `Shared/Tests/MessageProtocolTests.swift` (new file — or renamed, depending on git rename detection)
- `QuipiOS/Tests/MessageProtocolTests.swift` (deleted — may be shown as part of a rename instead)
- `QuipiOS/project.yml` (modified — adds `- path: ../Shared/Tests`)
- `QuipMac/project.yml` (modified — adds QuipMacTests target)
- `QuipiOS/QuipiOS.xcodeproj/project.pbxproj` (modified — xcodegen regen)
- `QuipMac/QuipMac.xcodeproj/project.pbxproj` (modified — xcodegen regen, with structural addition of the new test target)

**Expected NOT to be staged:** any `Info.plist`, any `QuipLinux/` or `QuipAndroid/` files, any `Signing.xcconfig` files, any `docs/` files. If any of these appear, STOP and investigate.

- [ ] **Step 6.7: Stage all Commit 2 changes**

Run:
```bash
git add \
  Shared/Tests/MessageProtocolTests.swift \
  QuipiOS/Tests/MessageProtocolTests.swift \
  QuipiOS/project.yml \
  QuipMac/project.yml \
  QuipiOS/QuipiOS.xcodeproj/project.pbxproj \
  QuipMac/QuipMac.xcodeproj/project.pbxproj
```

Staging the deleted path explicitly is safe — git will recognize it and either add the deletion or finalize the rename, depending on how rename detection resolves.

- [ ] **Step 6.8: Review the staged diff**

Run:
```bash
git diff --cached --stat
```

Expected output (approximately):
```
 QuipMac/QuipMac.xcodeproj/project.pbxproj  | XX ++++++
 QuipMac/project.yml                         | 13 ++++++
 QuipiOS/QuipiOS.xcodeproj/project.pbxproj  | XX ++++
 QuipiOS/Tests/MessageProtocolTests.swift    | 4 ----
 QuipiOS/project.yml                         | 1 +
 Shared/Tests/MessageProtocolTests.swift     | 4 ++++
 6 files changed, ~20 insertions(+), ~4 deletions(-)
```

(pbxproj line counts will be larger and variable depending on xcodegen's serialization. What matters is that the 6 files above are the ONLY ones staged.)

If git detected the file move as a rename, you'll see:
```
 QuipiOS/Tests/MessageProtocolTests.swift => Shared/Tests/MessageProtocolTests.swift | 4 ++++
```
instead of separate delete/create entries. Either form is fine.

- [ ] **Step 6.9: Create Commit 2**

Run:
```bash
git commit -m "$(cat <<'EOF'
Moved them protocol tests outta the iPhone tests folder and into Shared so the Mac can run 'em too. Stuck a brand new test target on the Mac side that runs the same test file through a conditional switch at the top — whichever module's compilin' the file gets imported. Nothin' new in the tests themselves; just movin' houses and addin' a second tenant.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds. Output shows the 6 files changed.

- [ ] **Step 6.10: Confirm Commit 2 landed**

Run:
```bash
git log -1 --stat
```

Expected: commit message matches, stat shows the 6 files.

---

## Task 7: Add new test coverage to the shared file

**Purpose:** Add 12 new test methods plus 4 new case entries in `testMessageTypeExtraction`. Each sub-step appends a distinct block of code to `Shared/Tests/MessageProtocolTests.swift`. No commit yet — Task 8 handles the commit after verification.

**Files:**
- Modify: `Shared/Tests/MessageProtocolTests.swift`

- [ ] **Step 7.1: Locate the insertion point for new round-trip tests**

Run:
```bash
grep -n "// MARK: - Round-trip tests" Shared/Tests/MessageProtocolTests.swift
```

Expected: one line of output with a line number. This is the `MARK` header for the existing round-trip test section. New round-trip tests for `DuplicateWindowMessage`, `CloseWindowMessage`, `OutputDeltaMessage`, and `TTSAudioMessage` will be inserted after this section (but before the `// MARK: - Edge cases` section).

Run:
```bash
grep -n "// MARK: -" Shared/Tests/MessageProtocolTests.swift
```

Expected: a list of MARK section headers. The sections in order should be approximately:
- `// MARK: - Outgoing messages (iPhone → Mac)`
- `// MARK: - Authentication messages`
- `// MARK: - Incoming messages (Mac → iPhone)`
- `// MARK: - MessageCoder.messageType`
- `// MARK: - Round-trip tests`
- `// MARK: - Edge cases`
- `// MARK: - Cross-platform JSON key compatibility`
- `// MARK: - Helpers`

Confirm the structure matches this expected layout before proceeding.

- [ ] **Step 7.2: Add DuplicateWindowMessage and CloseWindowMessage tests**

Use the Edit tool with this find-and-replace in `Shared/Tests/MessageProtocolTests.swift`:

**Find** (the existing `testQuickActionRoundTrip` method — unique anchor ending with its closing brace):

```swift
    func testQuickActionRoundTrip() throws {
        let original = QuickActionMessage(windowId: "rt-3", action: "clear_terminal")
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(QuickActionMessage.self, from: data))
        XCTAssertEqual(original.windowId, restored.windowId)
        XCTAssertEqual(original.action, restored.action)
    }
```

**Replace with** (the same method plus 4 new test methods appended):

```swift
    func testQuickActionRoundTrip() throws {
        let original = QuickActionMessage(windowId: "rt-3", action: "clear_terminal")
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(QuickActionMessage.self, from: data))
        XCTAssertEqual(original.windowId, restored.windowId)
        XCTAssertEqual(original.action, restored.action)
    }

    func testDuplicateWindowMessageEncoding() throws {
        let msg = DuplicateWindowMessage(sourceWindowId: "src-1")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "duplicate_window")
        XCTAssertEqual(dict["sourceWindowId"] as? String, "src-1")
    }

    func testDuplicateWindowRoundTrip() throws {
        let original = DuplicateWindowMessage(sourceWindowId: "src-rt")
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(DuplicateWindowMessage.self, from: data))
        XCTAssertEqual(original.sourceWindowId, restored.sourceWindowId)
        XCTAssertEqual(original.type, restored.type)
    }

    func testCloseWindowMessageEncoding() throws {
        let msg = CloseWindowMessage(windowId: "w-kill")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "close_window")
        XCTAssertEqual(dict["windowId"] as? String, "w-kill")
    }

    func testCloseWindowRoundTrip() throws {
        let original = CloseWindowMessage(windowId: "w-rt")
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(CloseWindowMessage.self, from: data))
        XCTAssertEqual(original.windowId, restored.windowId)
        XCTAssertEqual(original.type, restored.type)
    }
```

- [ ] **Step 7.3: Add OutputDeltaMessage and TTSAudioMessage tests**

Use the Edit tool with this find-and-replace in `Shared/Tests/MessageProtocolTests.swift`:

**Find** (the closing brace of the last `testCloseWindowRoundTrip` method just added, followed by a blank line and the next MARK — must be a unique anchor):

```swift
    func testCloseWindowRoundTrip() throws {
        let original = CloseWindowMessage(windowId: "w-rt")
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(CloseWindowMessage.self, from: data))
        XCTAssertEqual(original.windowId, restored.windowId)
        XCTAssertEqual(original.type, restored.type)
    }

    // MARK: - Edge cases
```

**Replace with** (adds 4 more test methods between `testCloseWindowRoundTrip` and the `// MARK: - Edge cases` header):

```swift
    func testCloseWindowRoundTrip() throws {
        let original = CloseWindowMessage(windowId: "w-rt")
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(CloseWindowMessage.self, from: data))
        XCTAssertEqual(original.windowId, restored.windowId)
        XCTAssertEqual(original.type, restored.type)
    }

    func testOutputDeltaMessageRoundTrip() throws {
        let original = OutputDeltaMessage(
            windowId: "w-od-1",
            windowName: "claude",
            text: "Hello from Claude\n",
            isFinal: true
        )
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(OutputDeltaMessage.self, from: data))
        XCTAssertEqual(original.type, restored.type)
        XCTAssertEqual(original.windowId, restored.windowId)
        XCTAssertEqual(original.windowName, restored.windowName)
        XCTAssertEqual(original.text, restored.text)
        XCTAssertEqual(original.isFinal, restored.isFinal)
    }

    func testOutputDeltaMessageDefaultIsFinal() throws {
        let msg = OutputDeltaMessage(windowId: "w1", windowName: "n", text: "t")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)
        XCTAssertEqual(dict["isFinal"] as? Bool, true)
    }

    func testTTSAudioMessageRoundTrip() throws {
        let original = TTSAudioMessage(
            windowId: "w-tts-1",
            windowName: "claude",
            sessionId: "sess-abc",
            sequence: 3,
            isFinal: false,
            audioBase64: "AAAAAA==",
            format: "wav"
        )
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(TTSAudioMessage.self, from: data))
        XCTAssertEqual(original.type, restored.type)
        XCTAssertEqual(original.windowId, restored.windowId)
        XCTAssertEqual(original.windowName, restored.windowName)
        XCTAssertEqual(original.sessionId, restored.sessionId)
        XCTAssertEqual(original.sequence, restored.sequence)
        XCTAssertEqual(original.isFinal, restored.isFinal)
        XCTAssertEqual(original.audioBase64, restored.audioBase64)
        XCTAssertEqual(original.format, restored.format)
    }

    func testTTSAudioMessageFormatDefaultsToWav() throws {
        let msg = TTSAudioMessage(
            windowId: "w1", windowName: "n", sessionId: "s", sequence: 0,
            isFinal: true, audioBase64: ""
        )
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)
        XCTAssertEqual(dict["format"] as? String, "wav")
    }

    // MARK: - Edge cases
```

- [ ] **Step 7.4: Add WindowState backward-compat tests**

Use the Edit tool with this find-and-replace in `Shared/Tests/MessageProtocolTests.swift`:

**Find** (the existing `testWindowFramePrecision` method — the last method before `// MARK: - Cross-platform JSON key compatibility`):

```swift
    func testWindowFramePrecision() throws {
        let frame = WindowFrame(x: 0.123456, y: 0.654321, width: 0.5, height: 0.5)
        let data = try JSONEncoder().encode(frame)
        let restored = try JSONDecoder().decode(WindowFrame.self, from: data)
        XCTAssertEqual(frame.x, restored.x, accuracy: 1e-10)
        XCTAssertEqual(frame.y, restored.y, accuracy: 1e-10)
    }
```

**Replace with** (the same method plus 4 new tests appended — 2 WindowState backward-compat + 2 optional-field round-trips):

```swift
    func testWindowFramePrecision() throws {
        let frame = WindowFrame(x: 0.123456, y: 0.654321, width: 0.5, height: 0.5)
        let data = try JSONEncoder().encode(frame)
        let restored = try JSONDecoder().decode(WindowFrame.self, from: data)
        XCTAssertEqual(frame.x, restored.x, accuracy: 1e-10)
        XCTAssertEqual(frame.y, restored.y, accuracy: 1e-10)
    }

    func testWindowStateBackwardCompatWithoutIsThinking() throws {
        // Old Mac builds don't populate `isThinking` or `folder` — verify the
        // custom init(from decoder:) defaults them correctly.
        let json = """
        {
          "id": "w1",
          "name": "Terminal",
          "app": "Terminal",
          "enabled": true,
          "frame": { "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0 },
          "state": "neutral",
          "color": "#FFFFFF"
        }
        """.data(using: .utf8)!

        let state = try XCTUnwrap(MessageCoder.decode(WindowState.self, from: json))
        XCTAssertFalse(state.isThinking, "isThinking should default to false when absent from JSON")
        XCTAssertNil(state.folder, "folder should default to nil when absent from JSON")
    }

    func testWindowStateRoundTripWithFolderAndIsThinking() throws {
        let original = WindowState(
            id: "w2", name: "zsh", app: "iTerm2", folder: "Quip",
            enabled: true,
            frame: WindowFrame(x: 0, y: 0, width: 1, height: 1),
            state: "busy", color: "#FF0000", isThinking: true
        )
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(WindowState.self, from: data))
        XCTAssertEqual(restored.folder, "Quip")
        XCTAssertTrue(restored.isThinking)
        XCTAssertEqual(original, restored)
    }

    func testLayoutUpdateRoundTripWithScreenAspect() throws {
        let original = LayoutUpdate(
            monitor: "Built-in",
            screenAspect: 1.777,
            windows: []
        )
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(LayoutUpdate.self, from: data))
        XCTAssertEqual(restored.screenAspect, 1.777, accuracy: 0.001)
    }

    func testTerminalContentMessageRoundTripWithScreenshot() throws {
        let original = TerminalContentMessage(
            windowId: "w1",
            content: "$ ls\n",
            screenshot: "iVBORw0KGgoAAAANSUhEUg=="
        )
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(TerminalContentMessage.self, from: data))
        XCTAssertEqual(restored.screenshot, "iVBORw0KGgoAAAANSUhEUg==")
    }
```

- [ ] **Step 7.5: Extend testMessageTypeExtraction with 4 new cases**

Use the Edit tool with this find-and-replace in `Shared/Tests/MessageProtocolTests.swift`:

**Find** (the existing `testMessageTypeExtraction` cases array — the last line of the case list plus the closing `]`):

```swift
            (#"{"type":"auth","pin":"123456"}"#, "auth"),
            (#"{"type":"auth_result","success":true,"error":null}"#, "auth_result"),
        ]
```

**Replace with** (adds 4 new cases before the closing `]`):

```swift
            (#"{"type":"auth","pin":"123456"}"#, "auth"),
            (#"{"type":"auth_result","success":true,"error":null}"#, "auth_result"),
            (#"{"type":"duplicate_window","sourceWindowId":"s1"}"#, "duplicate_window"),
            (#"{"type":"close_window","windowId":"w1"}"#, "close_window"),
            (#"{"type":"output_delta","windowId":"w1","windowName":"n","text":"x","isFinal":true}"#, "output_delta"),
            (#"{"type":"tts_audio","windowId":"w1","windowName":"n","sessionId":"s","sequence":0,"isFinal":true,"audioBase64":"","format":"wav"}"#, "tts_audio"),
        ]
```

- [ ] **Step 7.6: Count the new tests to verify nothing was missed**

Run:
```bash
grep -c "func test" Shared/Tests/MessageProtocolTests.swift
```

Expected: previous count + 12 new methods. The previous file (from before this task) had 28 test methods. Expected new count: **40**. If the count is not exactly 40, re-inspect each Edit step for missed or duplicated additions.

Run:
```bash
grep -c "duplicate_window\|close_window\|output_delta\|tts_audio" Shared/Tests/MessageProtocolTests.swift
```

Expected: **at least 8** matches (each new message name appears at least twice — once in its own test method and once in the `testMessageTypeExtraction` cases).

---

## Task 8: Commit 3 — Verify both test targets and commit the new coverage

**Purpose:** Run both test targets, confirm all tests (including the 12 new ones) pass on both iPhone and Mac, then commit.

**Files:**
- Final commit of: `Shared/Tests/MessageProtocolTests.swift`

- [ ] **Step 8.1: Run QuipMacTests with new coverage**

Run:
```bash
xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMacTests \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | tail -80
```

Expected: `** TEST SUCCEEDED **` in the final lines. **40 tests** should run and pass (28 existing + 12 new). The test output should mention the new test methods by name: `testDuplicateWindowMessageEncoding`, `testDuplicateWindowRoundTrip`, `testCloseWindowMessageEncoding`, `testCloseWindowRoundTrip`, `testOutputDeltaMessageRoundTrip`, `testOutputDeltaMessageDefaultIsFinal`, `testTTSAudioMessageRoundTrip`, `testTTSAudioMessageFormatDefaultsToWav`, `testWindowStateBackwardCompatWithoutIsThinking`, `testWindowStateRoundTripWithFolderAndIsThinking`, `testLayoutUpdateRoundTripWithScreenAspect`, `testTerminalContentMessageRoundTripWithScreenshot`.

**If any test fails:** STOP, inspect the failure output, and fix the specific failing test in `Shared/Tests/MessageProtocolTests.swift`. Do NOT commit with failing tests.

- [ ] **Step 8.2: Run QuipiOSTests with new coverage**

Run (replace `<IOS_SIM_NAME>` with the simulator name from Step 1.4):
```bash
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination "platform=iOS Simulator,name=<IOS_SIM_NAME>" \
  2>&1 | tail -80
```

Expected: `** TEST SUCCEEDED **`. Same 40 MessageProtocol tests pass, plus the existing `PTTStressTests` methods. The iOS run must show all 12 new test methods in its output, same as the Mac run.

- [ ] **Step 8.3: Check git status**

Run:
```bash
git status
```

Expected: exactly one modified file — `Shared/Tests/MessageProtocolTests.swift`. Nothing else should be modified. If you see other files, investigate (most likely cause: incidental xcodegen churn — if so, discard with `git checkout --` on the non-test-file paths).

- [ ] **Step 8.4: Stage and review**

Run:
```bash
git add Shared/Tests/MessageProtocolTests.swift
git diff --cached --stat
```

Expected: a single file listed, `Shared/Tests/MessageProtocolTests.swift`, with approximately `+100 lines, -0 lines` (12 new test methods plus 4 lines added to `testMessageTypeExtraction` — roughly 100 lines total added).

- [ ] **Step 8.5: Create Commit 3**

Run:
```bash
git commit -m "$(cat <<'EOF'
Wrote tests for them four message types we been shippin' without testin' — duplicate_window and close_window for the phone's long-press menu, output_delta for the streamin' text, and tts_audio for the voice playback. Also tacked on a couple checks for the window state to make sure if some old Mac build forgets to set isThinking or folder the decoder fills 'em in right, and two little round-trips for the screenAspect and screenshot fields that was slippin' through uncovered.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds. Output shows `1 file changed, ~100 insertions(+)`.

- [ ] **Step 8.6: Confirm Commit 3 landed**

Run:
```bash
git log -1 --stat
```

Expected: commit message matches, stat shows only `Shared/Tests/MessageProtocolTests.swift`.

- [ ] **Step 8.7: Verify the three-commit sequence on eb-branch**

Run:
```bash
git log --oneline -5
```

Expected: the three commits from this plan (Commit 1, 2, 3) should appear at the top in reverse chronological order:
1. **Commit 3** — starts with "Wrote tests for them four message types..."
2. **Commit 2** — starts with "Moved them protocol tests..."
3. **Commit 1** — starts with "Quit compilin' the protocol file..."

Below those should be the spec commit (`65db31a` or similar) and older commits.

---

## Do NOT push

Per `eb-branch` push policy in the user's memory, do **not** push these commits to GitHub without explicit confirmation from the user. All three commits live locally on `eb-branch` until the user says otherwise.

## Completion criteria

All of the following must be true when the plan is done:

1. `Shared/Tests/MessageProtocolTests.swift` exists and contains exactly 40 test methods (28 existing + 12 new).
2. `QuipiOS/Tests/MessageProtocolTests.swift` does NOT exist.
3. `QuipiOS/Tests/PTTStressTests.swift` still exists, unchanged.
4. `grep -c "func test" Shared/Tests/MessageProtocolTests.swift` returns exactly 40 (28 prior + 12 new).
5. `QuipiOS/project.yml` `QuipiOSTests.sources` contains `- path: Tests` and `- path: ../Shared/Tests` but NOT `- path: ../Shared`.
6. `QuipMac/project.yml` contains a `QuipMacTests` target with the described sources, dependencies, and settings.
7. `xcodebuild test` for QuipMacTests passes with all MessageProtocol tests green.
8. `xcodebuild test` for QuipiOSTests passes with all MessageProtocol tests green AND all PTTStressTests green.
9. Three focused commits exist on `eb-branch`, one per commit plan phase, each with blue-collar boomer voice commit messages per `CLAUDE.md`.
10. No commits are pushed to GitHub — all land locally per `eb-branch` push policy.
