# Mirror-Desktop Visibility Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the iPhone from rendering dimmed terminal rectangles for windows parked off-screen (inactive Space, disconnected monitor) when Mirror-desktop mode is ON, without regressing the Mirror-OFF path or the "enabled always shows" guarantee.

**Architecture:** Mac-side only. Add one stored `Bool isOnVisibleScreen` to `ManagedWindow`, populate it in `applyWindowSnapshot` using the same NSScreen coordinate-flip technique already used elsewhere in `WindowManager`, then tighten the `windowsForBroadcast` filter so terminals must be either on a visible screen *or* user-enabled to be broadcast. Phone-side rendering is unchanged — it keeps drawing whatever list it receives.

**Tech Stack:** Swift / SwiftUI, AppKit (`NSScreen`), XCTest. Xcode project via xcodegen at `QuipMac/QuipMac.xcodeproj`.

**Spec:** [`docs/superpowers/specs/2026-04-16-mirror-desktop-visibility-filter-design.md`](../specs/2026-04-16-mirror-desktop-visibility-filter-design.md)

---

## Running the tests

Target file: `Shared/Tests/MirrorDesktopFilterTests.swift` (compiled under the `QuipMacTests` target of the `QuipMac.xcodeproj`).

**From Xcode IDE:** Open `QuipMac/QuipMac.xcodeproj`, select the `QuipMac` scheme, press `⌘U`.

**From CLI:**
```bash
xcodebuild \
  -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  -destination 'platform=macOS' \
  test -only-testing:QuipMacTests/MirrorDesktopFilterTests
```

The `-only-testing` flag keeps the loop tight — the full test target takes noticeably longer.

---

## Task 1: Add `isOnVisibleScreen` to `ManagedWindow` and populate it

**Files:**
- Modify: `QuipMac/Services/WindowManager.swift` — the `ManagedWindow` struct (lines 13–65) and `applyWindowSnapshot` (lines 166–205)

**Why one task, not two:** The stored property without population is just an always-`true` field that changes nothing — tests that exercise the filter don't care until they see `false`, which only the populate code can produce. Shipping the field alone would be a commit with no observable effect. Keep the addition and the population together.

- [ ] **Step 1: Add the stored property to `ManagedWindow`**

Edit `QuipMac/Services/WindowManager.swift`. Locate the struct declaration starting at line 13. Add `isOnVisibleScreen` as the final stored property, with a default of `true`:

```swift
struct ManagedWindow: Identifiable, Sendable {
    let id: String                // Unique identifier (bundleId + windowNumber)
    let name: String              // Window title
    let app: String               // Application name
    var subtitle: String          // Directory path or secondary info
    let bundleId: String          // Application bundle identifier
    let icon: NSImage?            // App icon (non-Sendable but only used on MainActor)
    var isEnabled: Bool           // Whether this window participates in layouts
    var assignedColor: String     // Hex color from palette
    let pid: pid_t                // Process ID
    let windowNumber: CGWindowID  // CG window number
    var bounds: CGRect            // Current window frame
    var iterm2SessionId: String?
    /// True when the window's bounds center falls inside some currently-
    /// connected NSScreen. Populated fresh on every snapshot refresh —
    /// CG's `.optionOnScreenOnly` is not reliable for windows parked on
    /// inactive Spaces or disconnected monitors, so we re-check here.
    var isOnVisibleScreen: Bool = true
    // ... existing computed properties continue unchanged ...
```

The default `true` keeps the auto-synthesized memberwise initializer backward-compatible — existing call sites that omit the parameter still compile. This matters because the test helper and any future call site would otherwise break.

- [ ] **Step 2: Populate the flag in `applyWindowSnapshot`**

Replace the entirety of the `applyWindowSnapshot` method body (lines 166–205) with:

```swift
/// Apply pre-fetched window data on main. Merges with existing state, resolves icons.
func applyWindowSnapshot(_ raw: [RawWindowInfo]) {
    // Precompute once per snapshot. Accessing NSScreen.screens is MainActor-safe
    // and we're already on main here.
    let screens = NSScreen.screens
    let totalHeight = screens.map { $0.frame.maxY }.max() ?? 0

    var refreshed: [ManagedWindow] = []
    for info in raw {
        // CG bounds use top-left origin; NSScreen frames use bottom-left.
        // Flip the Y to compare against screen frames. Same technique as
        // `windows(for display:)` below.
        let flippedY = totalHeight - info.bounds.midY
        let center = CGPoint(x: info.bounds.midX, y: flippedY)
        let onScreen = screens.contains { $0.frame.contains(center) }

        let icon = NSRunningApplication(processIdentifier: info.pid)?.icon
        if let existing = windows.first(where: { $0.id == info.id }) {
            refreshed.append(ManagedWindow(
                id: info.id, name: info.name, app: info.app,
                subtitle: existing.subtitle, bundleId: info.bundleId, icon: icon,
                isEnabled: existing.isEnabled, assignedColor: existing.assignedColor,
                pid: info.pid, windowNumber: info.windowNumber, bounds: info.bounds,
                iterm2SessionId: existing.iterm2SessionId,
                isOnVisibleScreen: onScreen
            ))
        } else {
            refreshed.append(ManagedWindow(
                id: info.id, name: info.name, app: info.app,
                subtitle: "", bundleId: info.bundleId, icon: icon,
                isEnabled: false, assignedColor: assignColor(),
                pid: info.pid, windowNumber: info.windowNumber, bounds: info.bounds,
                iterm2SessionId: nil,
                isOnVisibleScreen: onScreen
            ))
        }
    }

    if !customOrder.isEmpty {
        var ordered: [ManagedWindow] = []
        for id in customOrder {
            if let w = refreshed.first(where: { $0.id == id }) { ordered.append(w) }
        }
        for w in refreshed where !customOrder.contains(w.id) {
            ordered.append(w)
            customOrder.append(w.id)
        }
        let activeIds = Set(refreshed.map(\.id))
        customOrder.removeAll { !activeIds.contains($0) }
        windows = ordered
    } else {
        windows = refreshed
        customOrder = refreshed.map(\.id)
    }
}
```

Changes vs. the original:
- Added the three lines that compute `screens`, `totalHeight`, and then per-window `flippedY`/`center`/`onScreen`.
- Both `ManagedWindow(...)` construction sites now pass `isOnVisibleScreen: onScreen`.
- Nothing else changed — the custom-order merge logic is untouched.

- [ ] **Step 3: Build and run existing tests**

Run from the repo root:

```bash
xcodebuild \
  -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  -destination 'platform=macOS' \
  test -only-testing:QuipMacTests/MirrorDesktopFilterTests
```

Expected: All three existing tests (`testMirrorOffShowsOnlyEnabledWindows`, `testMirrorOnShowsAllTerminalsPlusEnabledNonTerminals`, `testMirrorOnWithNoTerminalsStillShowsEnabledNonTerminals`) still PASS. No new tests yet — the new field is only populated, not yet consumed by the filter. Build must succeed.

If the build fails: almost always a typo in one of the two `ManagedWindow(...)` construction sites. Double-check both have `isOnVisibleScreen: onScreen` as the final argument.

- [ ] **Step 4: Commit**

```bash
git add QuipMac/Services/WindowManager.swift
git commit -m "Added a little flag to each window tellin' us whether it's actually drawn on a screen you can see right now. Ain't wired up to nothin' yet, just collectin' the info."
```

---

## Task 2: Extend the test helper with an `onVisibleScreen` parameter

**Files:**
- Modify: `Shared/Tests/MirrorDesktopFilterTests.swift` — the `mw(...)` helper at lines 13–28

No production-code change in this task. Just teaching the test helper how to fake an off-screen window so Task 3 can TDD the filter.

- [ ] **Step 1: Add the parameter to `mw()`**

Replace lines 13–28 in `Shared/Tests/MirrorDesktopFilterTests.swift` with:

```swift
    private func mw(
        id: String,
        bundleId: String,
        enabled: Bool,
        onVisibleScreen: Bool = true
    ) -> ManagedWindow {
        ManagedWindow(
            id: id,
            name: id,
            app: bundleId,
            subtitle: "",
            bundleId: bundleId,
            icon: nil,
            isEnabled: enabled,
            assignedColor: "#F5A623",
            pid: 1,
            windowNumber: 0,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            iterm2SessionId: nil,
            isOnVisibleScreen: onVisibleScreen
        )
    }
```

Changes: one new parameter with a `true` default, one new argument passed to the `ManagedWindow` init. Default keeps existing call sites untouched.

- [ ] **Step 2: Run the existing tests**

```bash
xcodebuild \
  -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  -destination 'platform=macOS' \
  test -only-testing:QuipMacTests/MirrorDesktopFilterTests
```

Expected: all three existing tests still PASS. No behavior change. The helper just grew one optional knob.

- [ ] **Step 3: Commit**

```bash
git add Shared/Tests/MirrorDesktopFilterTests.swift
git commit -m "Taught the test helper to fake off-screen windows so we can poke at the filter next."
```

---

## Task 3: TDD — Mirror-ON drops off-screen disabled terminals

This is the behavior change. Red-green-refactor: write a test that breaks the current filter, then tighten the filter until it passes.

**Files:**
- Modify: `Shared/Tests/MirrorDesktopFilterTests.swift` — add one new test method
- Modify: `QuipMac/Services/WindowManager.swift` — update `windowsForBroadcast` at lines 407–412

- [ ] **Step 1: Write the failing test**

Add this test method to `MirrorDesktopFilterTests` class in `Shared/Tests/MirrorDesktopFilterTests.swift`. Put it after `testMirrorOnWithNoTerminalsStillShowsEnabledNonTerminals` (line 66), just before the closing `}`:

```swift
    func testMirrorOnDropsOffScreenDisabledTerminals() {
        let all = [
            mw(id: "a", bundleId: iterm2, enabled: true, onVisibleScreen: true),
            mw(id: "b", bundleId: iterm2, enabled: false, onVisibleScreen: true),
            mw(id: "c", bundleId: terminal, enabled: false, onVisibleScreen: false),
        ]
        let ids = WindowManager.windowsForBroadcast(all, mirrorDesktop: true).map(\.id)
        XCTAssertEqual(Set(ids), Set(["a", "b"]),
                       "On: off-screen disabled terminals (other Space, disconnected monitor) are filtered out; on-screen terminals still appear.")
        XCTAssertFalse(ids.contains("c"),
                       "Disabled terminal with isOnVisibleScreen=false must not leak — that's the whole point of the visibility filter.")
    }
```

- [ ] **Step 2: Run the test — verify it FAILS**

```bash
xcodebuild \
  -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  -destination 'platform=macOS' \
  test -only-testing:QuipMacTests/MirrorDesktopFilterTests/testMirrorOnDropsOffScreenDisabledTerminals
```

Expected: FAILS with something like `XCTAssertEqual failed: ("[\"a\", \"b\", \"c\"]") is not equal to ("[\"a\", \"b\"]")`. The current filter is `$0.isTerminal || $0.isEnabled`, which lets the off-screen disabled terminal `c` through.

If the test passes unexpectedly: you likely forgot to pass `onVisibleScreen: false` for window `c`, or the helper default is wrong. Re-check.

- [ ] **Step 3: Update the filter**

Replace lines 407–412 in `QuipMac/Services/WindowManager.swift` with:

```swift
    nonisolated static func windowsForBroadcast(_ all: [ManagedWindow], mirrorDesktop: Bool) -> [ManagedWindow] {
        if mirrorDesktop {
            return all.filter { ($0.isTerminal && $0.isOnVisibleScreen) || $0.isEnabled }
        }
        return all.filter(\.isEnabled)
    }
```

Change: the Mirror-ON predicate went from `$0.isTerminal || $0.isEnabled` to `($0.isTerminal && $0.isOnVisibleScreen) || $0.isEnabled`. The Mirror-OFF branch is untouched.

The parentheses around the AND matter — without them, Swift's precedence still gives the same result (AND binds tighter than OR), but explicit parens spare the reader the precedence check.

- [ ] **Step 4: Run the new test — verify it PASSES**

```bash
xcodebuild \
  -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  -destination 'platform=macOS' \
  test -only-testing:QuipMacTests/MirrorDesktopFilterTests/testMirrorOnDropsOffScreenDisabledTerminals
```

Expected: PASS.

- [ ] **Step 5: Run the full test file — verify all existing tests still pass**

```bash
xcodebuild \
  -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  -destination 'platform=macOS' \
  test -only-testing:QuipMacTests/MirrorDesktopFilterTests
```

Expected: all four tests (three existing + the new one) PASS. The old tests used helper defaults of `onVisibleScreen: true`, so every window in those tests counts as visible — the new filter treats them identically.

- [ ] **Step 6: Commit**

```bash
git add Shared/Tests/MirrorDesktopFilterTests.swift QuipMac/Services/WindowManager.swift
git commit -m "Phone won't show terminals parked on another desk space no more — they was stackin' up like old invoices on the workbench."
```

---

## Task 4: Add regression tests — enabled windows survive off-screen, Mirror-OFF ignores the flag

Task 3 locked in the "drop off-screen disabled terminals" behavior. These two tests pin down the guarantees that were supposed to already hold — they should PASS on first run because Task 3's filter already implements them. If they fail, the filter has a bug.

**Files:**
- Modify: `Shared/Tests/MirrorDesktopFilterTests.swift` — add two new test methods

- [ ] **Step 1: Add the "enabled wins over visibility" test**

Append this method to `MirrorDesktopFilterTests` in `Shared/Tests/MirrorDesktopFilterTests.swift`, right after `testMirrorOnDropsOffScreenDisabledTerminals`:

```swift
    func testMirrorOnKeepsOffScreenEnabledWindows() {
        // Enabled browser off-screen: user activated it months ago, moved
        // to another Space. Should still appear on phone (A1 guarantee).
        // Disabled off-screen terminal: should NOT appear (regression check).
        let all = [
            mw(id: "browser", bundleId: browser, enabled: true, onVisibleScreen: false),
            mw(id: "term", bundleId: iterm2, enabled: false, onVisibleScreen: false),
        ]
        let ids = WindowManager.windowsForBroadcast(all, mirrorDesktop: true).map(\.id)
        XCTAssertEqual(Set(ids), Set(["browser"]),
                       "On: enabled wins over visibility — a browser the user turned on stays visible even when off-screen, while a disabled off-screen terminal is dropped.")
    }
```

- [ ] **Step 2: Add the "Mirror-OFF ignores visibility" test**

Append this method directly after the one from Step 1:

```swift
    func testMirrorOffIgnoresVisibilityFlag() {
        // With Mirror OFF, the new flag must not change anything — the
        // Mirror-OFF branch is supposed to be untouched by this feature.
        let all = [
            mw(id: "a", bundleId: iterm2, enabled: true, onVisibleScreen: false),
            mw(id: "b", bundleId: iterm2, enabled: false, onVisibleScreen: true),
        ]
        let ids = WindowManager.windowsForBroadcast(all, mirrorDesktop: false).map(\.id)
        XCTAssertEqual(Set(ids), Set(["a"]),
                       "Off: only enabled windows are broadcast, regardless of on-screen status. The visibility filter must not leak into the Mirror-OFF path.")
    }
```

- [ ] **Step 3: Run the two new tests — verify both PASS**

```bash
xcodebuild \
  -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  -destination 'platform=macOS' \
  test -only-testing:QuipMacTests/MirrorDesktopFilterTests
```

Expected: all six tests PASS (three original + Task 3's + these two).

If `testMirrorOnKeepsOffScreenEnabledWindows` fails: the filter is dropping enabled windows when off-screen. The `|| $0.isEnabled` clause in the Mirror-ON predicate is missing or wrong.

If `testMirrorOffIgnoresVisibilityFlag` fails: someone edited the Mirror-OFF branch. It should still be `all.filter(\.isEnabled)`.

- [ ] **Step 4: Commit**

```bash
git add Shared/Tests/MirrorDesktopFilterTests.swift
git commit -m "Couple more tests to make sure enabled windows stick around even when they slip off-screen, and the off switch still works like it always did."
```

---

## Task 5: Update the `windowsForBroadcast` docstring

The comment block above `windowsForBroadcast` still says "every terminal window also goes out, so the phone can see the full desktop at a glance" — no longer true. Bring it in line with the new behavior.

**Files:**
- Modify: `QuipMac/Services/WindowManager.swift` — the doc comment at lines 400–406

- [ ] **Step 1: Replace the doc comment**

Find the comment block immediately above `windowsForBroadcast` (should be around lines 400–406 after Task 3, though line numbers may drift). Replace it with:

```swift
    /// Filter the window list for LayoutUpdate broadcasts.
    ///
    /// Mirror OFF (default): only windows the user has explicitly enabled —
    /// Quip is an allowlist.
    ///
    /// Mirror ON: every terminal currently drawn on a connected screen goes
    /// out, so the phone shows the *visible* desktop at a glance. Off-screen
    /// terminals (inactive Space, disconnected monitor) are filtered out —
    /// CG's `.optionOnScreenOnly` isn't reliable here, so we re-check in
    /// `applyWindowSnapshot`. Enabled windows always ride along regardless
    /// of visibility, so a browser the user turned on, or a terminal that
    /// later slipped off-screen, doesn't disappear from the phone.
```

- [ ] **Step 2: Build and verify nothing else broke**

```bash
xcodebuild \
  -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  -destination 'platform=macOS' \
  test -only-testing:QuipMacTests/MirrorDesktopFilterTests
```

Expected: all six tests still PASS. Comment-only change.

- [ ] **Step 3: Commit**

```bash
git add QuipMac/Services/WindowManager.swift
git commit -m "Updated the scribbles above the filter so the next fella knows what it's really doin'."
```

---

## Task 6: Reword the Mirror-desktop setting description

The Settings caption still says "every Terminal.app and iTerm2 window shows up on the phone" — misleading now that off-screen terminals are filtered. Insert "visible" to match reality. Spec calls for a one-word change.

**Files:**
- Modify: `QuipMac/Views/SettingsView.swift` — line 75

- [ ] **Step 1: Update the caption**

In `QuipMac/Views/SettingsView.swift`, find line 75. Replace:

```swift
                Text("When on, every Terminal.app and iTerm2 window shows up on the phone — tap a dimmed one to start driving it. When off, only windows you've explicitly enabled are visible.")
```

With:

```swift
                Text("When on, every visible Terminal.app and iTerm2 window shows up on the phone — tap a dimmed one to start driving it. When off, only windows you've explicitly enabled are visible.")
```

One word changed: "every" → "every visible".

- [ ] **Step 2: Build to confirm SwiftUI still compiles**

```bash
xcodebuild \
  -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  -destination 'platform=macOS' \
  build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual check (optional but recommended)**

If running the Mac app is convenient: launch QuipMac, open Settings → General, look at the Phone Display section, confirm the new caption reads naturally. Not a blocker if the build succeeds — this is a text-only change.

- [ ] **Step 4: Commit**

```bash
git add QuipMac/Views/SettingsView.swift
git commit -m "Fixed the settings blurb so it don't lie about showin' every terminal — it's only the ones you can actually see now."
```

---

## Post-implementation verification (manual)

Tests cover the filter function in isolation. The NSScreen coordinate-flip populate logic in `applyWindowSnapshot` is deliberately not unit-tested (NSScreen is awkward to mock and the spec acknowledges this). Verify manually once on a machine with multiple Spaces or monitors:

1. Launch QuipMac.
2. Turn on "Mirror desktop terminals" in Settings → General.
3. Open a terminal on the current Space. Confirm it appears on the phone.
4. Move that terminal to a different Space (Mission Control drag, or `Ctrl+→`). Confirm it disappears from the phone within ~2 seconds (the snapshot refresh interval).
5. Move it back. Confirm it reappears.
6. Enable a window (tap it on the phone or use the context menu). Move it to another Space. Confirm it **still** appears on the phone (enabled wins).
7. Turn off Mirror-desktop. Confirm only the enabled windows remain — disabled terminals (visible or not) should drop out.

If step 4 never drops the window: `applyWindowSnapshot` isn't flipping the coordinate correctly, or `NSScreen.screens` is returning stale data. Check the math against `windows(for display:)` at lines 218–226, which uses the same technique and is known-good.

---

## Self-review notes

**Spec coverage check:**
- §Behavior, Mirror OFF unchanged → Task 3 leaves OFF branch untouched; Task 4's `testMirrorOffIgnoresVisibilityFlag` guards against regression. ✓
- §Behavior, Mirror ON changed filter rule → Task 3 Step 3. ✓
- §Behavior, enabled always wins → Task 4's `testMirrorOnKeepsOffScreenEnabledWindows`. ✓
- §Settings description reword → Task 6. ✓
- §Implementation #1 (ManagedWindow.isOnVisibleScreen) → Task 1 Step 1. ✓
- §Implementation #1 (populate via coord flip) → Task 1 Step 2. ✓
- §Implementation #2 (filter change) → Task 3 Step 3. ✓
- §Implementation #3 (Settings copy) → Task 6. ✓
- §Tests (all three new test cases) → Tasks 3 + 4. ✓
- §Tests (extend helper with default) → Task 2. ✓
- §Tests (existing three tests still pass) → verified after each task. ✓

**Placeholder scan:** No "TBD", no "handle edge cases", no "similar to Task N". All code blocks present. ✓

**Type consistency:** `isOnVisibleScreen` spelled the same way in struct, applyWindowSnapshot, test helper, and filter. `onVisibleScreen` (without `is`) used only as the test-helper parameter name by intent — avoids `isIsOnVisibleScreen` pseudo-Hungarian awkwardness at call sites. ✓

**Risk from spec: NSScreen stale during hotplug.** Spec accepts the 2s self-heal. Manual-verification step 4 covers this path. ✓
