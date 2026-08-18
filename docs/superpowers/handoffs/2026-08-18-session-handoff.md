# Session handoff — 2026-08-18

Branch: `eb-branch`, clean. Twelve commits ahead of `origin/eb-branch`, none
pushed (`main` is protected; landing needs a PR, which is the owner's call).

**Resume:** read this file, then `git log --oneline -6` and
`docs/superpowers/board.md`. Ready holds one new item (Q-20); everything else on
the board is a manual smoke.

## What shipped

The §58 review-hardening loop is now code-complete — all four iterations.

| Hash | Why |
| --- | --- |
| `316f483` | Iteration 2's last gap: client-side prompt-id validation. Sanitizer lifted into `Shared/PromptID.swift`; editor previews the real filename, blocks unsavable ids, warns on collisions. |
| `cf0f1b3` | Iteration 1: one window-order source, Arrange targets the selected display in AX coordinates, failures surface, sidebar numbers mean arrange slots. |
| `f42ae84` | Iteration 4 part one: spawn-path quoting (a real injection via an NSOpenPanel path), 11 icon-only Mac controls labelled, iOS prompt rows made VoiceOver-reachable, protocol docs for the acks. |
| `198b43c` | Iteration 4 part two: drag-to-resize actually resizes. Eight handles, `LayoutResize` arithmetic, Arrange consuming the same frames the preview draws. |

Suites at the end: harness 62 checks, QuipMac 727 tests, QuipiOS 763 tests — all
green through the pre-commit gate on every commit.

## Install state

| Target | Version | Note |
| --- | --- | --- |
| `/Applications/Quip.app` | built **Aug 18 11:30**, pid 88438 | Carries `198b43c`. Signature verified on the installed bundle. |
| iPhone 17 Pro Max | installed Aug 18 ~09:17 | Carries `f42ae84`'s predecessor `316f483`. Needs a force-quit + relaunch to load; not confirmed done. |

Two consequences of the Mac reinstall, both expected:

- **APNs is dark.** `push.log` logs `waiting_for_input skipped — APNs not
  configured`. Re-enter the `.p8` in Settings → Notifications.
- Accessibility / Screen Recording may need re-granting. Arrange now says so in
  an alert rather than doing nothing, with a button that opens the right pane.

## Verified vs not

| Change | Status |
| --- | --- |
| All four iterations | ✅ tests + builds; ⚠️ **no hardware smoke has been run for any of them** |
| Mac install carries the new code | ✅ `nm` shows `LayoutResize` + `PromptID`; fresh pid confirmed |
| Q-16 poll guards | ❌ **not verified** — see below |
| Q-18a multi-display | ❌ unrunnable, this machine has one display |

The Q-16 attempt is worth reading as a cautionary note: the iTerm window opened
for it never entered a tracked state, and three AppleScript `close` variants
returned success without closing it. The log came back clean because nothing was
exercised, not because the guard held. **iTerm window id 2962 may still be open
on the desktop.**

## The one finding that was not on any list

`push.log` shows 73 `neutral↔waiting_for_input` transitions in 2m50s for one busy
iTerm window — ~26/min. Single `cpuIdleThreshold = 5.0`, no hysteresis, and a
2-poll (0.5s) debounce that cannot absorb an agent oscillating across it.
Notifications are safe (30s per-window/device debounce elsewhere), so the cost is
badge flicker and a layout broadcast per transition. Filed as **Q-20** with the
fix shape; not built, because it changes when the phone says "waiting for input".

## Traps confirmed again today

- `xcodegen generate` before **every** build, not just after adding files. The
  committed `pbxproj` is stale by design (the gate restores it), so a cold
  Release build fails with ~30 `cannot find X in scope` errors that look like
  broken code and are not.
- `Shared/Tests/*.swift` compile into **both** test targets. A Mac-only symbol
  needs `#if os(macOS)`, and the import is `@testable import Quip`.
- The pre-commit gate takes ~90s; a two-minute Bash timeout kills it mid-run.
