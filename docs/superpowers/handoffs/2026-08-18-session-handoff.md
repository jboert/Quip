# Session handoff — 2026-08-18

Branch: `eb-branch`, clean. Fourteen commits ahead of `origin/eb-branch`, none
pushed (`main` is protected; landing needs a PR, which is the owner's call, and
so is the push itself).

**Resume:** read this file, then `git log --oneline -6` and
`docs/superpowers/board.md`. **The board's Ready column is empty — everything
left is a manual smoke that needs hands on hardware**, so the next session
should start by asking which smoke the owner wants to run rather than looking
for code to write.

## What shipped

The §58 review-hardening loop is now code-complete — all four iterations.

| Hash | Why |
| --- | --- |
| `316f483` | Iteration 2's last gap: client-side prompt-id validation. Sanitizer lifted into `Shared/PromptID.swift`; editor previews the real filename, blocks unsavable ids, warns on collisions. |
| `cf0f1b3` | Iteration 1: one window-order source, Arrange targets the selected display in AX coordinates, failures surface, sidebar numbers mean arrange slots. |
| `f42ae84` | Iteration 4 part one: spawn-path quoting (a real injection via an NSOpenPanel path), 11 icon-only Mac controls labelled, iOS prompt rows made VoiceOver-reachable, protocol docs for the acks. |
| `198b43c` | Iteration 4 part two: drag-to-resize actually resizes. Eight handles, `LayoutResize` arithmetic, Arrange consuming the same frames the preview draws. |
| `6a4e6f4` | Session log + this handoff, first pass. |
| `9aef9f8` | **Q-20 fixed** — asymmetric state debounce, kills the ~26/min flap. See below. |
| `1d1d211` | Board bookkeeping: four rows had `PENDING` where their hashes belong. |

Suites at the end: harness 62 checks, **QuipMac 738 tests**, QuipiOS 763 tests —
all green through the pre-commit gate on every commit.

## Install state

| Target | Version | Note |
| --- | --- | --- |
| `/Applications/Quip.app` | built **Aug 18 11:30**, pid 49931 | Carries `198b43c`. **Does not carry `9aef9f8`** — the flap fix is committed but not installed. Quit for the test run and relaunched; `stat` reports the bundle as Jun 20, which is `ditto` preserving the directory mtime, not a stale binary — this morning's install was verified by symbol count and a fresh `STARTED` line. |
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
| Q-20 flap fix | ✅ tests (11 cases, replays the measured shape); ❌ not on hardware — needs an install, tracked as **Q-20a** |

The Q-16 attempt is worth reading as a cautionary note: the iTerm window opened
for it never entered a tracked state, and three AppleScript `close` variants
returned success without closing it. The log came back clean because nothing was
exercised, not because the guard held. **iTerm window id 2962 may still be open
on the desktop.**

## The one finding that was not on any list — found, then fixed

`push.log` showed 73 `neutral↔waiting_for_input` transitions in 2m50s for one
busy iTerm window — ~26/min, against 2–7 for the others. Single
`cpuIdleThreshold = 5.0`, no hysteresis, and a 2-poll (0.5s) debounce that
cannot absorb an agent oscillating across it.

It looked like it needed a latency trade-off approved before building. It did
not, because the two directions were never symmetric and should not have shared
a threshold:

- **Raising** `waitingForInput` is the expensive mistake — it badges the phone
  grid and can push "an agent is asking you something" when it is not. Now needs
  **6 agreeing polls (1.5s)** of sustained quiet.
- **Clearing** it is cheap to get wrong and costly to get slow (a stale badge),
  so it keeps the original **2 polls (0.5s)**.

A real prompt idles indefinitely and still lands, ~1s later than before, against
a human reaction time measured in seconds. Logic is a pure
`TerminalStateDebounce` next to `TerminalPollGate`, testable without spawning
processes. The oracle is `test_alternatingPollsNeverTransition` — replays the
measured shape (two quiet polls, two busy, ×200) and asserts **zero**
transitions. The pending candidate is also dropped on `untrackWindow`,
`stopMonitoring`, `trackWindow` and both STT writes.

**Q-20a** is the hardware confirmation: after installing, drive a busy agent ~3
minutes and count the transitions for that window. Baseline to beat is 73 in
2m50s; expect single digits. Confirm a real prompt still badges within ~2s.

## Traps confirmed again today

- `xcodegen generate` before **every** build, not just after adding files. The
  committed `pbxproj` is stale by design (the gate restores it), so a cold
  Release build fails with ~30 `cannot find X in scope` errors that look like
  broken code and are not.
- `Shared/Tests/*.swift` compile into **both** test targets. A Mac-only symbol
  needs `#if os(macOS)`, and the import is `@testable import Quip`.
- The pre-commit gate takes ~90s; a two-minute Bash timeout kills it mid-run.

## Open threads for the owner

1. **Install the flap fix?** Not done unilaterally — a Mac reinstall wipes the
   Accessibility and Screen Recording grants re-approved this morning. Worth
   batching with the APNs `.p8` re-entry, which is owed regardless.
2. **Re-enter the APNs `.p8`** (Settings → Notifications). Push is dark until then.
3. **Four smokes need hands:** Q-19b (resize), Q-18a (order; the multi-display
   half needs a second monitor), Q-16 (properly, against a window actually
   running an agent CLI), Q-17a (prompt CRUD — the phone needs a force-quit and
   relaunch first).
4. **Fourteen commits sit local.** Pushing and opening the PR both need explicit
   per-action approval and have not been requested.
