# Multi-iTerm2-window Keystroke Targeting via Session `unique id`

Fix the Mac-side `KeystrokeInjector` so iPhone-originated keystrokes, text input, and terminal content reads actually land in the correct iTerm2 window when multiple are open — by addressing AppleScript commands to iTerm2 sessions by their stable `unique id` (UUID) instead of the broken `id of w` / CGWindowID match pattern.

## Background

When the user has multiple iTerm2 windows open and selects one on the iPhone, every iPhone-triggered keystroke (`Return`, `Ctrl+C`, `Tab`, `Escape`, `Backspace`), text injection (`SendTextMessage`), and terminal-content read (`RequestContentMessage`) currently fires the AppleScript at whichever iTerm2 window is frontmost — NOT at the window the user selected on the phone. It only works reliably in single-window use because `front window == selected window` by coincidence.

The root cause is a latent bug in `QuipMac/Services/KeystrokeInjector.swift`. Both `sendText`, `sendKeystroke`, and `readContent` contain this AppleScript pattern:

```applescript
tell application "iTerm2"
    try
        repeat with w in windows
            if id of w is <cgWindowNumber> then    -- NEVER MATCHES
                tell current session of w
                    ...
                end tell
                return
            end if
        end repeat
    end try
    tell current session of front window            -- ALWAYS THE FALLBACK
        ...
    end tell
end tell
```

iTerm2's AppleScript `id of w` attribute returns iTerm2's own internal window identifier — small integers like `447`, `1159`, `1154`. But Quip passes in a `CGWindowID` — typically >10000. The `is` comparison never matches, the `repeat` block silently never fires, and we always hit the `front window` fallback. An existing explicit `NOTE on window targeting` comment at `KeystrokeInjector.swift:427-441` acknowledges this and names the needed fix: *"it needs a different identifier like iTerm2 session unique id, or a lower-level AX-based keystroke injection that bypasses System Events entirely."*

Commit `465d5b5` reverted an earlier broken attempt at the fix (`4006db4`) and restored the "use front window" fallback. The underlying bug never got a real fix.

Wishlist reference: item #13 in `docs/superpowers/wishlist.md`.

**Status of related work:**
- The AppleScript **transport** for iTerm2 is already using the native `write text` / `write text (character id N)` verbs — the wishlist's recommended "option (c)" is in place for iTerm2 from commit `e37a9e9` onward. Only the **window targeting** remains broken.
- Terminal.app has its own (separate) window-targeting story — `keystrokeScript()` uses a bare `activate` + System Events path that relies on `windowManager.focusWindow()` having raised the right window. Terminal.app's AppleScript window model doesn't expose CGWindowID directly. That's tracked as its own concern and is **out of scope for this spec**.

## Overview

Address each AppleScript command to a specific iTerm2 session via the session's stable `unique id` (a UUID string like `"36E1F4BC-8A70-4E80-B1F9-6C4AE12A27A3"`) instead of trying to match the enclosing window's integer id against a CGWindowID that will never line up. Cache the session unique id on the Mac side at window registration time as a new optional field on `ManagedWindow`, and thread it through to the injector.

Deliberately narrow scope:

- **What is in this spec:**
  - A new optional `iterm2SessionId: String?` field on `ManagedWindow` (Mac-side only).
  - Registration-time probe in `WindowManager` that runs an AppleScript lookup per iTerm2 window and caches the current session's `unique id`.
  - Rewritten AppleScript in `sendText`, `sendKeystroke`, and `readContent` that selects by `unique id of s` instead of `id of w`. Fallback path to `front window` remains for the case where the cached id is nil or the session has gone away.
  - Wire-through in `QuipMacApp.swift` so every call site that invokes the injector also passes `managedWindow.iterm2SessionId`.

- **What is NOT in this spec:**
  - **No protocol changes.** `Shared/MessageProtocol.swift` is not touched. `iterm2SessionId` is Mac-side-only local state — the phone doesn't need to know about it, doesn't send it, doesn't receive it.
  - **No iOS changes.** `QuipiOS/`, `QuipLinux/`, `QuipAndroid/` are not touched at all. The iPhone keeps sending the same `SendTextMessage` / `QuickActionMessage` / `RequestContentMessage` it always has. The fix is entirely in the Mac's handling of those messages.
  - **No Terminal.app targeting fix.** Terminal.app's broken window targeting is a separate wishlist concern (related to its AppleScript window model) and is tracked separately.
  - **No tab-switching awareness.** If an iTerm2 window has multiple tabs and the user switches tabs after Quip cached the session id, the cached id points at the original session (which may no longer be current). The `write text` AppleScript still targets the cached session by UUID, which may be MORE correct ("write to the session the user originally selected") than "write to whatever's current right now." A proactive refresh-on-tab-change is out of scope for v1.
  - **No pre-populated Quip-initiated tab creation.** We don't spawn extra tabs, we don't track them, we don't do any tab management.
  - **No session-refresh policy.** If the cached id becomes invalid (session closed, iTerm2 restarted), the AppleScript's existing fallback-to-front-window path covers it. Proactive cache invalidation and re-probe is out of scope for v1.

## Mac-Side Changes

### 1. `QuipMac/Models/WindowInfo.swift` — add optional field to `ManagedWindow`

Add a new optional `iterm2SessionId: String?` property to `ManagedWindow` (or whatever the local Mac-side managed-window type is called, to be verified at plan time). The field is:

- Optional — only populated for iTerm2 windows where the probe succeeded. Nil for Terminal.app windows and for iTerm2 windows where the probe failed.
- String-valued — stores the UUID string returned by `unique id of session`.
- Persisted in memory only — not saved to disk, not serialized over WebSocket.
- Populated exactly once at window registration time and never updated for the lifetime of the `ManagedWindow` entry (if the underlying session goes away or changes, the next registration cycle re-probes).

### 2. `QuipMac/Services/WindowManager.swift` — session id probe

At the point where `WindowManager` registers a new iTerm2 window (or refreshes its known-window list after a layout change), run a short AppleScript probe per window to fetch the session unique id. Rough shape:

```applescript
tell application "iTerm2"
    try
        repeat with w in windows
            if id of w is <itermInternalWindowId> then
                return unique id of current session of w
            end if
        end repeat
    end try
    return ""
end tell
```

Note: the probe uses iTerm2's internal window id (which we CAN read — `id of w` returns it reliably), which is a small integer. That's different from the CGWindowID the rest of Quip uses. The WindowManager already has to know both for other reasons (the CGWindowID for AX / screencapture, the iTerm2 internal id from some source — to be verified at plan time).

If the probe fails, times out, or returns an empty string, store nil on `ManagedWindow.iterm2SessionId`. The consuming code then falls back to the existing `front window` path, which is strictly no worse than current behavior.

**If the plan reveals that WindowManager doesn't currently have access to iTerm2's internal window id for each window**, the probe needs a different anchor — most likely iterating by enumeration position (window 1, window 2, ...) and using `name of w` or `bounds of w` to match against the CGWindow bounds the WindowManager already has. That fallback strategy is a plan-time decision.

### 3. `QuipMac/Services/KeystrokeInjector.swift` — AppleScript rewrites

Three functions need the same shape of change: accept an optional `iterm2SessionId: String?` parameter, and when non-nil, emit an AppleScript that addresses the specific session by UUID instead of the broken window match.

**`sendText(to:pressReturn:terminalApp:windowName:cgWindowNumber:)` — add `iterm2SessionId: String?` param.** The iTerm2 branch becomes:

```applescript
tell application "iTerm2"
    try
        repeat with w in windows
            repeat with s in sessions of w
                if unique id of s is "<cached-uuid>" then
                    tell s
                        write text "<text>" newline <yes|no>
                    end tell
                    return
                end if
            end repeat
        end repeat
    end try
    -- Fallback: front window (only reached if cached id is nil or session gone)
    tell current session of front window
        write text "<text>" newline <yes|no>
    end tell
end tell
```

When `iterm2SessionId == nil`, emit the current broken matching script unchanged. This preserves existing behavior for callers that don't have a cached session id, and makes the change backwards compatible across the codebase during the transition.

**`sendKeystroke(_ key:to:terminalApp:cgWindowNumber:windowIndex:)` — add `iterm2SessionId: String?` param.** Same shape: the iTerm2 branch's AppleScript becomes a UUID-based session selection. The `write text (character id <charId>)` verb inside the `tell s` block is unchanged — only the targeting changes.

**`readContent(terminalApp:cgWindowNumber:)` — add `iterm2SessionId: String?` param.** The `contents of` read path becomes:

```applescript
tell application "iTerm2"
    try
        repeat with w in windows
            repeat with s in sessions of w
                if unique id of s is "<cached-uuid>" then
                    tell s
                        return contents
                    end tell
                end if
            end repeat
        end repeat
    end try
    tell current session of front window
        return contents
    end tell
end tell
```

### 4. `QuipMac/QuipMacApp.swift` — thread the session id through

Every call site in `QuipMacApp.swift` that invokes `keystrokeInjector.sendText`, `keystrokeInjector.sendKeystroke`, or `keystrokeInjector.readContent` needs to pass `managedWindow.iterm2SessionId` as the new argument. Based on the earlier grep, the call sites are approximately:

- `sendText` — 1 call site at `QuipMacApp.swift:433` (the `send_text` message handler)
- `sendText` for fixed-string actions — 4 call sites in the `quick_action` handlers (`press_return`, `press_y`, `press_n`, `clear_context`, `restart_claude`) around lines 622-660
- `sendKeystroke` — 6 call sites in the `quick_action` handlers (`ctrl_c`, `ctrl_d`, `escape`, `tab`, `backspace`, etc.) around lines 626-658
- `readContent` — 5 call sites for view-output and output-polling reads around lines 241, 300, 477, 512, 681, 685

All ~15 call sites thread `managedWindow.iterm2SessionId` through. For code paths where the window is being looked up via `windowManager.windows.first(where: { $0.id == msg.windowId })`, the session id comes from that same managed window. For Terminal.app code paths, the parameter is passed as nil (because Terminal.app doesn't have iTerm2 sessions).

## iOS / Wire Protocol Side

**No changes.** `Shared/MessageProtocol.swift` is not touched. `QuipiOS/` is not touched. The wire protocol is entirely unchanged. The fix is 100% Mac-internal.

## Commit Plan

**Single commit on `eb-branch`.** All 4 file changes ship atomically:

1. `QuipMac/Models/WindowInfo.swift` — new `iterm2SessionId` field
2. `QuipMac/Services/WindowManager.swift` — session id probe at registration
3. `QuipMac/Services/KeystrokeInjector.swift` — AppleScript rewrites + new parameter
4. `QuipMac/QuipMacApp.swift` — thread session id through ~15 call sites

Splitting this into multiple commits isn't productive: each piece alone leaves the code in a half-working state (new field but nobody populates it; probe but nobody reads the cache; injector accepts a new parameter but nobody passes it), and the fix only demonstrates its benefit when all four pieces are in place. Testing the intermediate state wouldn't meaningfully cover the target fix either.

Draft commit message (blue-collar voice, release-note quality):

> Fixed the thing where tappin' Return on the phone would land on whichever iTerm window was out front instead of the one you actually picked. Turns out iTerm's window id is its own internal number that's got nothin' to do with the window id the rest of the Mac uses, so the matcher was never hittin'. Grab each session's unique id at startup now, stash it on the window record, and point the AppleScript at that session by UUID when firin' keystrokes or typin' text. Single iTerm window still works like before; the fix kicks in when you got two or more open.

## Pre-Commit Safety Gate

Before the commit lands, the developer must verify the fix works end-to-end with multiple iTerm2 windows. The verification procedure is manual and physical — there's no way to assert multi-window targeting in a unit test without a running Mac + iTerm2.

**Manual test matrix:**

1. **Single-window baseline.** Close all but one iTerm2 window. From the iPhone, send text via voice / shortcut button. Text lands in the only open window. **Expected:** same as before, no regression.
2. **Two-window, target second.** Open two iTerm2 windows. Select the SECOND one on the iPhone (via the phone's window list). Without raising the second window on the Mac (leave the first as frontmost), tap Return on the iPhone. **Expected:** Return lands in the SECOND window, not the frontmost first one. **This is the core regression test.**
3. **Two-window, ctrl+c variant.** Same setup as #2, but tap Ctrl+C instead of Return. **Expected:** Ctrl+C fires in the selected (non-frontmost) window.
4. **Two-window, view output variant.** Same setup as #2, but request the terminal content via the phone's "View Output" button. **Expected:** content returned is from the selected (non-frontmost) window.
5. **Three-window, cycle through.** Open three iTerm2 windows. Use the phone's chevron buttons to cycle through them. Tap Return on each. **Expected:** each Return lands in the matching window, in order.
6. **Quip restart.** Quit and relaunch QuipMac with multi-window setup still open. From the iPhone, tap Return on a non-frontmost window. **Expected:** targeting still works — confirms the session id probe runs correctly on restart.

**If any of 2–6 fails with a post-fix commit**, the fix is incomplete and needs further investigation. Typical failure modes to watch for:
- The session id cache didn't populate (probe returned empty string)
- `unique id of s` doesn't match the cached string (whitespace? case? trailing nulls?)
- The AppleScript falls through to `front window` unexpectedly (malformed script)

## Testing

**No automated tests for this change.** The target code is an AppleScript embedded in a Swift string — round-trip unit tests can assert the Swift code generates a string that LOOKS right, but they can't assert the actual AppleScript behavior against a running iTerm2. Automated integration tests against iTerm2 are feasible but represent their own multi-day effort; not in scope for this fix.

**Protocol round-trip tests (from #21) DO continue to apply** — they verify that `SendTextMessage`, `QuickActionMessage`, and `RequestContentMessage` serialize and deserialize correctly. Since those messages aren't being modified, the existing tests give us "the wire protocol is unchanged" confidence for free.

**The 39 existing + 12 new tests in `Shared/Tests/MessageProtocolTests.swift`** must still pass after this change — no message struct is touched, so they should pass trivially, but running them is the safety gate.

## Risks and Known Unknowns

- **`unique id` of session returns a string format Quip doesn't expect.** iTerm2's AppleScript dictionary documents `unique id` as a string, and empirically it's a UUID format like `"36E1F4BC-..."`, but a future iTerm2 update could theoretically change the format. The comparison in our AppleScript is an exact string match (`unique id of s is "<cached>"`), so as long as the string format is consistent between probe-time and use-time within a single Quip session, we're fine. Cross-session drift (Quip caches UUIDs but iTerm2 rotates them on restart) is mitigated by the fact that WindowManager re-probes on every registration cycle — i.e., whenever QuipMac restarts or re-enumerates windows.
- **`sessions of w` iteration is O(tabs × windows).** For a reasonable number of windows (<20) and tabs-per-window (<10), this is a ~200-element loop, negligible. If a power user has hundreds of iTerm2 sessions open, the AppleScript gets slower — but so does everything else in that scenario.
- **Session id lookup at registration time adds startup latency.** One AppleScript round-trip per iTerm2 window at QuipMac launch. Probably ~5–20ms per window, should be imperceptible for typical setups.
- **Fallback path to `front window` is strictly the same behavior as today's bug.** If the cached id is nil or doesn't match, we hit the fallback. That's the current broken behavior. So the change is monotonically non-regressive: either we do better (targeted session) or we do the same (fallback).
- **Code paths that don't yet use ManagedWindow.iterm2SessionId.** Any new code added after this change that invokes the injector needs to remember to pass the session id. Missing this would silently regress to the fallback behavior. Mitigation: a short code comment near the injector methods, and ideally a non-defaulted parameter so the compiler flags missing call sites. Final decision is a plan-time call.
- **Terminal.app is unaffected.** This spec explicitly doesn't touch the Terminal.app window-targeting story. Users who switch to Terminal.app from iTerm2 will still hit the separate "front window" behavior there. Documented as out of scope.
- **iTerm2 version/AppleScript dictionary drift.** If iTerm2 renames `unique id` in a future update, this breaks. Mitigation: companion wishlist item **#25** (iTerm2 version smoke test against AppleScript verbs) would catch this in seconds. Out of scope for this item but worth flagging as a reason to also do #25.

## Related Wishlist Items

- **#13** (this item) — source wishlist entry in `docs/superpowers/wishlist.md`. Status in entry: *"Wishlist — partial fix attempted, had to be reverted."*
- **#25** (iTerm2-version smoke test) — the natural companion for this fix. Would catch verb-shape drift in iTerm2's AppleScript dictionary in seconds instead of after a real user report.
- **#1** (`/plan` shortcut button) — the user's stated next priority after #13. The reason #13 is being done first is that #1's buttons invoke `sendText`, which is one of the three functions being fixed here. Landing #13 removes the "which iTerm2 window does the /plan button target" reliability concern before adding more such buttons.
- **#11** (window ID stability across QuipMac restarts) — conceptually related (both are about window-identity robustness) but orthogonal in implementation. #11 is about Quip's own internal window IDs surviving across restarts; #13 is about iTerm2's session IDs surviving within a single Quip session.
- **#21** (protocol round-trip tests) — just shipped in this session. Provides the "wire protocol is solid" layer of confidence underneath #13 — we know the messages travel correctly, now we're fixing where they land.

## Completion Criteria

All of the following must be true when this fix is done:

1. `ManagedWindow` has an optional `iterm2SessionId: String?` field.
2. `WindowManager` populates this field at registration time for iTerm2 windows (or stores nil if the probe fails).
3. `KeystrokeInjector.sendText`, `sendKeystroke`, and `readContent` each accept an `iterm2SessionId: String?` parameter, and when non-nil, emit AppleScript that selects the session by `unique id` match.
4. Every call site in `QuipMacApp.swift` that invokes these three functions passes through `managedWindow.iterm2SessionId`.
5. All 51 iOS tests and 40 Mac tests from #21 continue to pass.
6. `xcodebuild build` for both QuipMac and QuipiOS succeeds.
7. Manual multi-iTerm2-window test (at least test #2 from the pre-commit safety gate matrix above) confirms the Return keystroke lands in the selected window instead of the frontmost.
8. Single commit on `eb-branch` with the blue-collar commit message.
9. No changes to `Shared/MessageProtocol.swift`, `QuipiOS/`, `QuipLinux/`, or `QuipAndroid/`.
