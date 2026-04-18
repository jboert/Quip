# MessageProtocol Round-Trip Tests — Mac + iPhone Coverage

Add cross-platform round-trip tests for every message type in `Shared/MessageProtocol.swift`, close the coverage gap for the 4 untested message types, and introduce a `QuipMacTests` target so protocol tests run on every Mac build — not just iPhone.

## Background

`Shared/MessageProtocol.swift` (283 lines) defines the wire format for WebSocket messages between the iPhone remote and the Mac host. Every commit that adds or modifies a message type is an opportunity to ship one side without the other and silently drop messages until a feature breaks in manual testing. Swift's exhaustive-switch checker catches some cases at compile time but not all — a JSON `CodingKey` mismatch, a missing field, or a custom `init(from decoder:)` that drops a value will only fail at runtime and only if the specific message happens to round-trip during manual verification.

`QuipiOS/Tests/MessageProtocolTests.swift` (349 lines) already provides substantial coverage — encoding, decoding, and round-trip tests for 13 message types plus the `MessageCoder.messageType` extractor and the `.sortedKeys` JSON output guarantee. But four recent additions ship completely untested:

1. `DuplicateWindowMessage` — added in commit `44033ee` as part of the iPhone tab-management feature.
2. `CloseWindowMessage` — added in the same commit.
3. `OutputDeltaMessage` — streaming terminal delta (Mac → phone), multi-field with an `isFinal` default.
4. `TTSAudioMessage` — pre-synthesized audio chunks for TTS playback with `sessionId` / `sequence` / `isFinal` streaming semantics (Mac → phone). Eight fields, streaming-sequence semantics, easy to get wrong.

Two `WindowState` backward-compatibility code paths aren't tested either: the custom `init(from decoder:)` at `MessageProtocol.swift:52-63` defaults `isThinking` to `false` when absent from JSON and treats `folder` as an optional field, both for backward compat with older Mac builds. Removing those defaults by accident would silently break old-client communication.

Two optional-field round-trips are also missing: `LayoutUpdate.screenAspect` (added to let clients render correctly-proportioned thumbnails) and `TerminalContentMessage.screenshot` (optional base64 image payload). Silently dropping either would be invisible to the existing tests.

A larger structural gap: **QuipMac has no test target at all.** `QuipMac/project.yml` defines only the `QuipMac` application target. The protocol is compiled into QuipMac via `- path: ../Shared` in the app target's sources, but no Mac-side test exercises it. Mac-only changes to `MessageProtocol.swift` can ship broken and only get caught when the iPhone fails to communicate with the Mac during manual verification. The wishlist entry explicitly requires *"Run on every Mac and iPhone build."*

Finally, a minor pre-existing wart: `QuipiOS/project.yml`'s `QuipiOSTests` target sources both `- path: Tests` **and** `- path: ../Shared`, while also depending on `QuipiOS` (which itself compiles `../Shared`). This creates two parallel compilations of `MessageProtocol.swift`: one in the `QuipiOS` module, one in the `QuipiOSTests` module. Swift resolves them independently via `@testable import QuipiOS`, so the tests currently exercise the test-target's **own** copy of the protocol, not the app's — a subtle form of the exact "two sides of the wire disagree silently" trap the tests are supposed to catch. Fortunately the two copies come from the same source file, so in practice they're byte-identical; but the duplication is wasteful and slightly misleading. Worth fixing while we're in the area.

Wishlist reference: item #21 in `docs/superpowers/wishlist.md`.

## Overview

Three related changes land as three focused commits:

1. **Remove the `../Shared` duplicate compilation** from the `QuipiOSTests` target's sources so tests exercise `QuipiOS`'s own protocol types via `@testable import`, not a parallel test-target copy.
2. **Move `MessageProtocolTests.swift` from `QuipiOS/Tests/` to `Shared/Tests/`** and introduce a new `QuipMacTests` target that sources the same file. A conditional `@testable import` block at the top of the shared file selects the right module per target.
3. **Add the missing test coverage** — 4 new round-trip tests, 2 backward-compat decode tests, 2 optional-field round-trips, and 4 new `testMessageTypeExtraction` cases.

Scope is deliberately narrow:

- **What is in this spec:**
  - One shared test file at `Shared/Tests/MessageProtocolTests.swift`, running under both `QuipiOSTests` and `QuipMacTests` targets.
  - A new `QuipMacTests` target added to `QuipMac/project.yml`.
  - The `QuipiOS/project.yml` duplicate-compilation fix as a standalone preceding commit.
  - Coverage for `DuplicateWindowMessage`, `CloseWindowMessage`, `OutputDeltaMessage`, `TTSAudioMessage`, `WindowState.isThinking` backward compat, `WindowState.folder` backward compat, `LayoutUpdate.screenAspect` round-trip, `TerminalContentMessage.screenshot` round-trip, and extension of `testMessageTypeExtraction`.
  - `PTTStressTests.swift` stays put at `QuipiOS/Tests/PTTStressTests.swift` — it's iOS-specific (`HardwareButtonHandler`, `@MainActor`) and has no shared relevance.

- **What is NOT in this spec:**
  - No rewriting of the existing passing tests — they migrate unchanged.
  - No property-based / fuzz testing infrastructure.
  - No CI configuration or pre-commit hooks (same rationale as #14 — out of scope).
  - No Equatable / Hashable conformances added to message structs. Per-field comparison in tests works fine and is the existing pattern.
  - No tests for QuipLinux or QuipAndroid protocol layers — iOS/macOS scope only. Those platforms have their own protocol implementations and their own separate test story.
  - No renaming or reshaping of message types. The coverage is additive.

## File Layout Changes

| Before | After |
|---|---|
| `QuipiOS/Tests/MessageProtocolTests.swift` (349 lines) | **Moves to** `Shared/Tests/MessageProtocolTests.swift` (grows by ~80 lines for new tests) |
| `QuipiOS/Tests/PTTStressTests.swift` | **Stays in place** — iOS-specific, untouched |
| *(no `Shared/Tests/` directory)* | **New directory** `Shared/Tests/` containing the moved file |
| `QuipMac/project.yml` has only `QuipMac` target | **Adds** `QuipMacTests` target |
| `QuipiOS/project.yml` QuipiOSTests has `- path: Tests` + `- path: ../Shared` | **Updated** to `- path: Tests` + `- path: ../Shared/Tests` |

## The `@testable import` split

Top of the shared test file becomes:

```swift
import XCTest

#if canImport(QuipiOS)
@testable import QuipiOS
#elseif canImport(QuipMac)
@testable import QuipMac
#endif
```

Each test target's compilation sees exactly one `@testable import` line active. All `MessageProtocol` types are `internal`-access (verified by inspection of `MessageProtocol.swift` — no `private`, `fileprivate`, or `public` modifiers on any type in the file), so `@testable import` gives full test visibility on both platforms without any new access modifiers.

## `QuipiOS/project.yml` Changes

Current `QuipiOSTests` target definition:

```yaml
QuipiOSTests:
  type: bundle.unit-test
  platform: iOS
  sources:
    - path: Tests
    - path: ../Shared
  dependencies:
    - target: QuipiOS
  settings:
    base:
      PRODUCT_BUNDLE_IDENTIFIER: com.quip.QuipiOSTests
      TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Quip.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Quip"
      BUNDLE_LOADER: "$(TEST_HOST)"
```

**Commit 1 edit** (remove duplicate compilation): delete the `- path: ../Shared` line entirely. Tests will see the protocol types through `@testable import QuipiOS`.

After Commit 1:

```yaml
QuipiOSTests:
  type: bundle.unit-test
  platform: iOS
  sources:
    - path: Tests
  dependencies:
    - target: QuipiOS
  # ...settings unchanged...
```

**Commit 2 edit** (add new shared test location): add a second `- path: ../Shared/Tests` entry after the existing `- path: Tests`.

After Commit 2:

```yaml
QuipiOSTests:
  type: bundle.unit-test
  platform: iOS
  sources:
    - path: Tests          # still sources PTTStressTests.swift
    - path: ../Shared/Tests  # sources the moved MessageProtocolTests.swift
  dependencies:
    - target: QuipiOS
  # ...settings unchanged...
```

## `QuipMac/project.yml` Changes (Commit 2)

Add a new `QuipMacTests` target alongside the existing `QuipMac` target:

```yaml
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

Key differences from `QuipiOSTests`:

- `platform: macOS` (not iOS)
- Deployment target matches QuipMac's `MACOSX_DEPLOYMENT_TARGET: "14.0"`
- `TEST_HOST` points at the macOS `.app`'s MacOS binary path (not the iOS `.app` executable folder)
- Only one source path — `../Shared/Tests` — no iOS-specific tests to include

Both `.xcodeproj/project.pbxproj` files are regenerated by `xcodegen generate` during Commit 2. The regenerated pbxproj files are part of that commit (real structural additions, not cosmetic drift — this is the exception to #14's "discard incidental pbxproj churn" rule).

## New Test Coverage

All new tests go into the moved `Shared/Tests/MessageProtocolTests.swift` file. Each test follows the existing style — construct an instance, encode, decode back (or decode from a JSON string literal), assert field equality.

### Four missing message types — round-trip each

**`DuplicateWindowMessage`:**

```swift
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
```

**`CloseWindowMessage`:**

```swift
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

**`OutputDeltaMessage`:**

```swift
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
    // Verify the init default `isFinal: Bool = true` flows through the encoded JSON
    let msg = OutputDeltaMessage(windowId: "w1", windowName: "n", text: "t")
    let data = try XCTUnwrap(MessageCoder.encode(msg))
    let dict = try jsonDict(from: data)
    XCTAssertEqual(dict["isFinal"] as? Bool, true)
}
```

**`TTSAudioMessage`:**

```swift
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
    // Verify the init default `format: String = "wav"` flows through the encoded JSON
    let msg = TTSAudioMessage(
        windowId: "w1", windowName: "n", sessionId: "s", sequence: 0,
        isFinal: true, audioBase64: ""
    )
    let data = try XCTUnwrap(MessageCoder.encode(msg))
    let dict = try jsonDict(from: data)
    XCTAssertEqual(dict["format"] as? String, "wav")
}
```

### Two `WindowState` backward-compat decode tests

```swift
func testWindowStateBackwardCompatWithoutIsThinking() throws {
    // Old Mac builds don't populate `isThinking` — verify decoder defaults to false
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
    // Verify both fields round-trip when present
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
    // WindowState is Equatable, so we can also do a full equality check:
    XCTAssertEqual(original, restored)
}
```

The `testWindowStateBackwardCompatWithoutIsThinking` test is the important one — it locks in the defaulting behavior that silently would be lost if anyone ever removed the custom `init(from decoder:)`.

### Two optional-field round-trips

```swift
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
        screenshot: "iVBORw0KGgoAAAANSUhEUg=="  // tiny fake PNG base64
    )
    let data = try XCTUnwrap(MessageCoder.encode(original))
    let restored = try XCTUnwrap(MessageCoder.decode(TerminalContentMessage.self, from: data))
    XCTAssertEqual(restored.screenshot, "iVBORw0KGgoAAAANSUhEUg==")
}
```

### Extend `testMessageTypeExtraction`

Add four cases to the existing `testMessageTypeExtraction` test's case list, so the type-extraction path covers all message types:

```swift
// Added to the existing cases array:
(#"{"type":"duplicate_window","sourceWindowId":"s1"}"#, "duplicate_window"),
(#"{"type":"close_window","windowId":"w1"}"#, "close_window"),
(#"{"type":"output_delta","windowId":"w1","windowName":"n","text":"x","isFinal":true}"#, "output_delta"),
(#"{"type":"tts_audio","windowId":"w1","windowName":"n","sessionId":"s","sequence":0,"isFinal":true,"audioBase64":"","format":"wav"}"#, "tts_audio"),
```

## Commit Plan

### Commit 1 — QuipiOS test target duplicate-compilation fix

**Files touched:**
- `QuipiOS/project.yml` — remove `- path: ../Shared` from `QuipiOSTests.sources`
- `QuipiOS/QuipiOS.xcodeproj/project.pbxproj` — regenerated by xcodegen

**Verification before committing:**
- `xcodegen generate` in `QuipiOS/` → succeeds
- `xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination 'platform=iOS Simulator,name=<first available iPhone>' test` → all **existing** tests still green (this commit doesn't add tests, only removes structural redundancy, so a green run proves the @testable import path still resolves the protocol types correctly)

**Draft commit message:**

> Quit compilin' the protocol file into the iPhone test target twice, once through the app and once through the Shared path. Only needed it once, so I told it to pick the one that comes in through @testable and leave the other alone.

### Commit 2 — Move tests to Shared + add QuipMacTests target

**Files touched:**
- `Shared/Tests/MessageProtocolTests.swift` — new file (content-identical to the old QuipiOS/Tests version but with the conditional `@testable import` block prepended)
- `QuipiOS/Tests/MessageProtocolTests.swift` — deleted
- `QuipiOS/project.yml` — add `- path: ../Shared/Tests` to `QuipiOSTests.sources`
- `QuipMac/project.yml` — add the new `QuipMacTests` target block
- `QuipiOS/QuipiOS.xcodeproj/project.pbxproj` — regenerated
- `QuipMac/QuipMac.xcodeproj/project.pbxproj` — regenerated (includes new test target — real structural addition, not cosmetic drift)

**Verification before committing:**
- `xcodegen generate` in both `QuipiOS/` and `QuipMac/` → both succeed
- `xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS,arch=arm64' test` → **new** QuipMacTests target runs the existing test suite and passes
- `xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination 'platform=iOS Simulator,name=<first available iPhone>' test` → QuipiOSTests still passes with MessageProtocolTests now sourced from Shared/Tests/
- Both must be green before committing

**Draft commit message:**

> Moved them protocol tests outta the iPhone tests folder and into Shared so the Mac can run 'em too. Stuck a brand new test target on the Mac side that runs the same test file through a conditional switch at the top — whichever module's compilin' the file gets imported. Nothin' new in the tests themselves; just movin' houses and addin' a second tenant.

### Commit 3 — Add missing test coverage

**Files touched:**
- `Shared/Tests/MessageProtocolTests.swift` — add 4 missing message tests + 2 backward-compat decode tests + 2 optional-field round-trips + extend `testMessageTypeExtraction` case list

**Verification before committing:**
- `xcodebuild test` for both QuipMac and QuipiOS targets → all tests including the new ones pass on both platforms
- The new tests must specifically be visible in the test output (not silently skipped)

**Draft commit message:**

> Wrote tests for them four message types we been shippin' without testin' — duplicate_window and close_window for the phone's long-press menu, output_delta for the streamin' text, and tts_audio for the voice playback. Also tacked on a couple checks for the window state to make sure if some old Mac build forgets to set isThinking or folder the decoder fills 'em in right, and two little round-trips for the screenAspect and screenshot fields that was slippin' through uncovered.

## Testing / Verification

Every commit is gated on both test targets running green. The verification procedure is identical for all three commits, parameterized by which targets exist at that point in the timeline:

**Commit 1 verification:**
```bash
cd QuipiOS && xcodegen generate && cd ..
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=<first available iPhone>' test
```
(QuipMac has no test target yet in Commit 1; only QuipiOS is tested.)

**Commit 2 verification:**
```bash
cd QuipMac && xcodegen generate && cd ..
cd QuipiOS && xcodegen generate && cd ..

xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS,arch=arm64' test

xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=<first available iPhone>' test
```

**Commit 3 verification:** same two `xcodebuild test` invocations as Commit 2.

**iOS simulator selection:** If the `<first available iPhone>` simulator isn't running, the command will boot one and may take ~30 seconds the first time. List available simulators with `xcrun simctl list devices available | grep iPhone` and pick the first one.

**Xcode CLI build permission:** Per the lesson from #14's Step 7.5, the subagent sandbox may block `xcodebuild test`. If that happens, the implementer reports `BLOCKED` or `DONE_WITH_CONCERNS`, the controller either runs the test manually or escalates to the user to run it.

## Risks and Known Unknowns

- **xcodegen regeneration of `.xcodeproj/project.pbxproj`.** Unlike #14 where pbxproj changes were cosmetic and discarded, Commit 2 **intentionally** commits pbxproj changes (the new test target is a real structural addition). Risk: xcodegen may ALSO emit cosmetic reordering on existing entries, making the pbxproj diff noisy. Mitigation: diff the pbxproj carefully during Commit 2 review — the test-target addition should be a contiguous block, and any cosmetic reordering should be separable. If noise dominates signal, pin the xcodegen version in the plan.

- **iOS simulator availability on the developer's machine.** `xcodebuild test` for QuipiOS requires an installed simulator. If no iPhone simulator is installed, the command fails and the implementer is stuck. Mitigation: the plan's verification step explicitly runs `xcrun simctl list devices available` first and picks a simulator name dynamically. If none are available, install one via Xcode → Settings → Components before proceeding.

- **QuipMacTests bundle identifier collision.** The proposed `com.quip.QuipMacTests` identifier needs to be unique in the local signing identity space. Unlikely to collide, but if it does, signing will fail on first run. Mitigation: the plan includes a pre-flight `grep -r "com.quip.QuipMacTests"` against all `project.yml` files to confirm no collision.

- **`@testable` visibility silently breaking.** If any future commit adds a `private` or `fileprivate` type to `MessageProtocol.swift`, the shared tests stop compiling with `cannot find 'X' in scope`. That's intended feedback (you need to either make it `internal` or expose a test accessor), but worth mentioning so it doesn't surprise anyone. Today every type in the file is default-access (internal) — verified by inspection.

- **PTTStressTests impact from Commit 1's duplicate-compilation fix.** Removing `- path: ../Shared` from `QuipiOSTests.sources` means the test target no longer directly compiles `MessageProtocol.swift`. `PTTStressTests.swift` (which stays in `QuipiOS/Tests/`) uses `@testable import QuipiOS` and only references `HardwareButtonHandler` — an iOS-specific class that lives in QuipiOS proper, not in Shared. Verified by reading the file. Commit 1 is safe.

- **Cross-platform JSON key compatibility.** The tests already include `testSortedKeysEncoding` which asserts JSON key ordering for cross-platform compatibility with `QuipAndroid/Protocol.kt`. This spec does not extend that coverage to the 4 new message types. If we wanted strict Android-parity verification, we'd need to either duplicate the sorted-key test per message or parameterize it — both add more surface area than the wishlist entry requested. Deferred to a future wishlist item if cross-platform parity becomes a concern again.

- **Test runtime impact.** Adding 12 new test methods to the existing ~25 doubles the test suite size. At ~1ms per test (typical for pure encode/decode without network or UI), total test runtime goes from ~25ms to ~50ms. Negligible. The Mac test target also takes a few hundred ms of setup overhead per run, which is unavoidable. Both well under the threshold where "tests are slow" becomes a real problem.

## Related Wishlist Items

- **#21** (this item) — source wishlist entry in `docs/superpowers/wishlist.md`.
- **#12** (silent failure diagnostics) — same flavor of concern. Protocol round-trip tests catch a different class of silent failure (JSON serialization drift) than #12's runtime-observability instrumentation, but both address the category of "message silently drops and nobody notices."
- **#14** (gitignore generated Info.plist) — just shipped (commit `6ca6f60`). This spec inherits the lesson from #14's Step 7.5: `xcodebuild` in the subagent sandbox may fail with a permission gate, and the plan should handle that with explicit BLOCKED/DONE_WITH_CONCERNS handoff rather than silent skip.

## Completion Criteria

All of the following must be true when the plan is done:

1. `Shared/Tests/MessageProtocolTests.swift` exists and contains the full test suite including 12 new test methods beyond what existed in the iOS version.
2. `QuipiOS/Tests/MessageProtocolTests.swift` no longer exists (the move is complete, not a copy).
3. `QuipiOS/Tests/PTTStressTests.swift` still exists, unchanged.
4. `QuipiOS/project.yml` `QuipiOSTests.sources` contains `- path: Tests` and `- path: ../Shared/Tests` but NOT `- path: ../Shared`.
5. `QuipMac/project.yml` contains a `QuipMacTests` target with the described sources, dependencies, and settings.
6. `xcodebuild test` for QuipMacTests passes with all shared MessageProtocol tests green.
7. `xcodebuild test` for QuipiOSTests passes with all shared MessageProtocol tests green AND PTTStressTests still green.
8. Three focused commits exist on `eb-branch`, one per commit plan phase.
9. Each commit's message is in blue-collar boomer voice per `CLAUDE.md`.
10. No commits are pushed to GitHub — all land locally per `eb-branch` push policy.
