# Session handoff — 2026-09-08

## What was asked

Make the phone work across the apps on the Mac desktop, and across the screens
on a Mac Studio: the terminal often lives on the second monitor, and toggling
back and forth has to be one tap. Test it and confirm it works.

It did not work. Two features were missing outright and two coordinate bugs sat
underneath them.

## Commits

- `c5aa63e` — `feat(multi-display)`: per-screen window frames, phone screen
  chips, and text into any app. The whole fix; details below.
- `f425d07` — `docs`: backlog entry recording the four defects, what shipped for
  each, and the two open threads (hardware acceptance, iOS suite unrunnable).

`eb-branch` is **5 ahead of `origin/eb-branch`** and has NOT been pushed —
pushing needs the owner's explicit go-ahead (see Open threads).

## The four defects

Reproduced with the reporting desk's real geometry (3440x1440 ultrawide primary,
2560x1440 monitor to its right):

```
focus on primary:     second-screen window -> x = 1.047   OFF-CANVAS
focus on 2nd screen:  primary window       -> x = -1.266  OFF-CANVAS
per-own-display:      both                 -> 0.058 / 0.062  on-canvas
```

1. `broadcastLayout` normalized EVERY window against ONE display, so anything on
   a second screen arrived outside the phone's 0-1 canvas. Second-screen windows
   still listed and were tappable — they just drew off the thumbnail.
2. "Which display" was `NSScreen.main` — the *focused* screen, not the primary.
   Clicking the other monitor re-based every window AND changed
   `LayoutUpdate.monitor`, which `BackendConnectionManager.isSameMac` treats as a
   same-Mac identity signal.
3. Nothing about displays existed on the wire, so no screen toggle was buildable.
4. `terminalAppForWindow` answers `.terminal` for every unrecognized bundle id,
   and that path runs `tell application "Terminal" to activate` + keystroke into
   `process "Terminal"` — so dictating into a Slack/Xcode card typed into
   Terminal.app's shell.

## What shipped

- `Shared/DisplayGeometry.swift` — Foundation-only pure math both peers use:
  normalize against own display, desktop span, compose back for a merged canvas.
  Mac splits, phone composes; the round trip is pinned by test.
- Wire: `LayoutUpdate.displays` + `spanAspect`, `WindowState.displayID` — all
  optional, so older peers decode and render unchanged.
- `DisplayInfo.isMain` → `isPrimary` (`NSScreen.screens.first`); id is now the
  `CGDirectDisplayID`, not an enumeration index.
- `applyWindowSnapshot` re-enumerates displays every poll tick, so hot-plugging a
  monitor registers (previously only `MainWindow`/`MenuBarView` refreshed it).
- Phone: compact chip row (one per screen + "All") filtering the grid and
  switching canvas aspect; persists per backend; falls back to "All" when the
  pinned monitor is unplugged; hidden entirely on a one-screen Mac.
- Generic injection: `sendTextToApp` / `sendKeystrokeToApp` / `pasteImageToApp`
  target by **unix id** and raise before typing. `send_text`, `image_upload`, and
  quick actions branch on `isFirstClassHost`; shell-only verbs (clear / restart /
  scrollback) refuse out loud rather than typing literal text into a chat box.
- New Mac setting **"Mirror every app"** (off by default) — without it a
  non-terminal window can only reach the phone by being enabled by hand.

## Install state

| Thing | State |
|---|---|
| `/Applications/Quip.app` | Release, rebuilt + `ditto`'d this session, binary mtime `Sep 8 14:17:02 2026`, signed `Developer ID Application: Fintech Adventures LLC (D2PM6R797Q)` at build time. Relaunched, fresh pid 36091. |
| iPhone 17 Pro Max (`FA951BBB-D706-5FCF-9886-3E57560E9030`) | Debug build installed via `devicectl`, bundle `com.quip.QuipiOS`. **Not force-quit/relaunched**, so the running process may still be the old bundle. |
| Stale build copies | Both `DerivedData/QuipMac-*/Build/Products/Debug/Quip.app` unregistered from LaunchServices and deleted; `/tmp/quip-mac-dd`, `/tmp/quip-ios-dd` removed. Only `/Applications/Quip.app` remains for `com.quip.mac`. |
| pbxproj | Restored after every xcodegen run; working tree clean except the pre-existing untracked `QuipMac/QuipMac.xcodeproj/xcshareddata/`. |

## Verified vs install-only

| Claim | Evidence |
|---|---|
| Per-display normalization is correct | **Test-verified.** `Shared/Tests/DisplayGeometryTests.swift` + two new cases in `WindowOrderAndDisplayTests` cover the ultrawide + right-hand monitor, a monitor left of primary (negative CG x), a taller secondary (negative CG y), gaps between mismatched monitors, and the split/compose round trip. |
| Generic-app injection routing + key table | **Test-verified.** `QuipMac/Tests/GenericAppInjectionTests.swift`: pid targeting not name targeting, raise-before-type ordering, loud failure when the process is gone, full key table, nil for unknown keys. |
| Mirror-every-app filter | **Test-verified.** 4 new cases in `MirrorDesktopFilterTests`, including "strictly wider than mirrorDesktop" and "still yields to a QA pair". |
| Both suites | **Run.** QuipMac 758 tests / QuipiOS 772 tests, `TEST SUCCEEDED` both. |
| Chips render, toggle, and place windows correctly on a real two-monitor desk | **NOT verified.** Only `C34J79x` was attached all session; chips are hidden below two displays. |
| Dictation actually lands in Slack/Xcode | **NOT verified.** Needs the TCC re-grant plus a phone relaunch. |
| Focus-follows bug is gone | **NOT verified.** Invisible on a single-screen desk by construction. |

## Open threads

1. **Hardware acceptance flow.** Plug in monitor #2, move an iTerm window to it,
   force-quit the phone app from the app switcher and relaunch (`devicectl
   install` replaces the bundle but does not kill the process), then: chip row
   appears; tap monitor 2 → only its windows, correctly placed; tap back → one
   tap each way; "All" → both screens on one wide canvas; click a window on
   monitor 2 **on the Mac** and confirm the phone grid does NOT jump (defect 2);
   Settings → Phone → Mirror every app on, select a Slack card, dictate, confirm
   the text lands there; with a non-terminal selected tap Clear and expect the
   refusal toast with nothing typed anywhere.
2. **TCC re-grant.** The Mac was rebuilt, so Accessibility and Screen Recording
   may need re-checking. Without Accessibility no keystroke lands anywhere.
3. **QuipiOS suite cannot run on this machine.** `xcodebuild -scheme QuipiOS`
   fails with "This scheme builds an embedded Apple Watch app. watchOS 26.5 must
   be installed" — the watchOS SDK is present, the *simulator runtime* is not, so
   `tools/check.sh`'s iOS gate reports a failure rather than a skip. Worked around
   by generating a watch-free spec (strip the `QuipWatch` target, the `- target:
   QuipWatch` dependency, and the empty `dependencies:` key it leaves behind).
   Real fix is either `xcodebuild -downloadPlatform watchOS` (large download, ask
   first) or teaching `check.sh` the fallback.
4. **Push is blocked pending the owner.** `eb-branch` is 5 ahead of
   `origin/eb-branch`. Standing rule: never push without explicit confirmation,
   even when a commit request is chained with one. `main` also rejects direct
   pushes, so landing needs a PR.

## Resume in a fresh session

> Read `docs/superpowers/handoffs/2026-09-08-session-handoff.md`, then walk the
> hardware acceptance flow for the multi-display chips and any-app dictation
> shipped in `c5aa63e` — start the tail of `~/Library/Logs/Quip/*.log` and check
> `netstat -an | grep 8765` before asking me to touch the phone.
