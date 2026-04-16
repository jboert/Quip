# Mirror-desktop visibility filter

**Status:** Design
**Date:** 2026-04-16
**Author:** Erick (with Claude)

## Problem

With "Mirror desktop terminals" turned on, the iPhone renders a dimmed rectangle for every terminal window the Mac's CG scan returns — including terminals that aren't actually visible to the user. On a multi-Space or multi-monitor dev setup, CG's `.optionOnScreenOnly` still leaks windows whose bounds are parked at off-screen coordinates (inactive Space, disconnected display). The phone view fills up with rectangles you can't see or reach, cluttering the layout and making the "new project" flow feel noisy and slow.

## Goal

When Mirror desktop is ON, the phone should only show terminals that are actually drawn on a currently-connected screen, plus any windows the user has explicitly enabled (even if those later become off-screen). When OFF, behavior is unchanged.

## Non-goals

- Not adding a new setting. The existing Mirror desktop toggle stays.
- Not redesigning the phone's layout rendering. Phone keeps rendering whatever list it receives.
- Not changing behavior when Mirror is OFF.
- Not investigating or fixing the "new project" spawn latency (`selectNewWindowAfterSpawn` polling). Separate concern.

## Behavior

### Mirror desktop OFF (unchanged)

Only `isEnabled` windows are broadcast. Identical to today.

### Mirror desktop ON (changed)

A window is broadcast if:

- it is `isEnabled`, OR
- it is a terminal AND its bounds-center lies within some currently-connected `NSScreen`.

Meaning:

- A terminal on another Space, on a disconnected monitor, or otherwise parked off-all-screens **stops appearing** on the phone.
- An enabled window that later becomes off-screen (user minimized it, moved it to another Space) **still appears** on the phone. Enabled always wins.
- A terminal the user hasn't enabled and that's not currently on-screen is dropped.

### Settings description

The toggle description in `SettingsView.swift` is reworded so the word "visible" appears — the current copy says "every Terminal.app and iTerm2 window shows up on the phone" which is now misleading.

## Implementation

Mac-side only. Three files touched.

### 1. `ManagedWindow` gains `isOnVisibleScreen`

File: `QuipMac/Services/WindowManager.swift`

Add a stored `Bool` property. Populated during `applyWindowSnapshot` using the same CG-to-NSScreen coordinate-flip technique already used by `windows(for display:)` at lines 218–226:

```
totalHeight = max maxY across NSScreen.screens
flippedY    = totalHeight - window.bounds.midY
center      = (bounds.midX, flippedY)
isOnVisibleScreen = any screen.frame.contains(center)
```

Because `applyWindowSnapshot` is `@MainActor`, accessing `NSScreen.screens` is safe there.

`ManagedWindow` currently has no screen-visibility awareness; this is net-new state derived at each snapshot refresh (no migration, no persistence).

### 2. `windowsForBroadcast` filter change

File: `QuipMac/Services/WindowManager.swift:407`

Current:

```swift
nonisolated static func windowsForBroadcast(
    _ all: [ManagedWindow], mirrorDesktop: Bool
) -> [ManagedWindow] {
    if mirrorDesktop {
        return all.filter { $0.isTerminal || $0.isEnabled }
    }
    return all.filter { $0.isEnabled }
}
```

New rule when `mirrorDesktop == true`:

```swift
return all.filter { ($0.isTerminal && $0.isOnVisibleScreen) || $0.isEnabled }
```

Mirror-OFF branch untouched.

### 3. Settings copy

File: `QuipMac/Views/SettingsView.swift:75`

Reword to reflect the "visible" qualifier. Target: one-sentence tweak, no other copy changes.

## Tests

File: `Shared/Tests/MirrorDesktopFilterTests.swift`

Extend the `mw(...)` test helper to take an `onVisibleScreen: Bool = true` parameter.

New cases:

1. **Mirror ON drops off-screen disabled terminals.** Given one on-screen enabled terminal, one on-screen disabled terminal, and one off-screen disabled terminal, broadcast contains only the first two.

2. **Mirror ON keeps off-screen enabled windows (A1 assertion).** Given one off-screen enabled browser and one off-screen disabled terminal, broadcast contains only the browser. Confirms "enabled wins over visibility" and "disabled + off-screen is dropped."

3. **Mirror OFF keeps enabled windows regardless of visibility.** Given one off-screen enabled terminal and one on-screen disabled terminal, broadcast (Mirror OFF) contains only the enabled one. Asserts Mirror-OFF path ignores the new flag.

Existing three tests still pass unmodified because they default `onVisibleScreen` to `true`.

## Risks

- **False negatives in off-screen detection.** If `NSScreen.screens` reports a stale set during a display hotplug, a legitimately visible window could momentarily be filtered out. Mitigation: the scan re-runs every ~2s (`refreshWindowList` timer), so any blip self-heals on the next refresh. Not worth code complexity to paper over a 2s edge case.
- **CG reporting bounds as (0,0,0,0)** for some short-lived windows. These already fail the `bounds.width < 50` guard at `WindowManager.swift:152` and never enter the list. No additional handling needed.
- **Enabled window that user forgot about.** If the user enabled a window months ago that now lives on an inactive Space, it'll still show on the phone (by design — A1). The existing "Remove from Phone" affordance in `WindowRectangle` context menu remains the escape hatch.

## Out of scope

- Spawn latency (`selectNewWindowAfterSpawn` polls up to 3s).
- Any "already open in this directory" check when spawning a new window.
- Phone-side layout changes (trays, pickers, opt-in flows — considered and rejected in favor of the simpler server-side filter).
