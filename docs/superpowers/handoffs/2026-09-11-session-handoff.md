# Session handoff — 2026-09-11

## What was asked

"go" — resume from the 2026-09-10 handoff, whose stated next step was walking
the desktop-chip interactions. That half-happened: the chip row was confirmed on
hardware in the first screenshot. The rest of the session went somewhere else,
because the same screenshot carried a red toast:

```
Text send failed: iTerm2 session not yet mapped for window com.googlecode.iterm2.808
```

Chasing it found one bug, then a second instance of the same bug, and a missing
log that had been hiding both.

## Commits

| Hash | Why |
|---|---|
| `00d2f1e` | `fix(iterm2)` — a failed AppleScript no longer unmaps every window. The toast's root cause. |
| `9a4ac75` | `feat(diagnostics)` — failed injections write `injection.log`. The injector had no on-disk record of a failure at all. |
| `ac6348c` | `docs` — wishlist session log for the above. |
| `b9dbeec` | `fix(tts)` — a stale session map no longer reports itself as a permissions problem. Same defect class, found by following the first fix's lead. |
| `c4b107c` | `docs` — close wishlist thread 5, which had been written as a suspicion earlier the same session. |

`eb-branch` is **7 commits ahead of `origin/eb-branch`** and has **not** been
pushed. Per standing policy, pushing needs an explicit go-ahead.

## The bug: one timed-out AppleEvent unmapped nine windows

Neither a Spaces regression nor a lost TCC grant — both ruled out by
measurement, not argument. iTerm2's `id of w` equals the CGWindowID for all nine
live windows (808 included), bounds identical to the pixel, so the matcher and
the Automation grant were both healthy.

The defect was one collapsed return value. `fetchIterm2SessionIds()` returned a
bare `[Iterm2SessionInfo]`, so **"the AppleScript failed" and "iTerm2 has no
windows" were the same value** — `AppleScriptRunner.Output.failed` was computed
and then discarded. `applyIterm2SessionIds` opens by clearing every mapping
before re-matching, so one failed fetch unmapped all nine at once and every send
failed until a later fetch happened to succeed.

`ensureITermSessionResolved` — written specifically to heal this — made it
worse, because it calls the same fetch. A failed heal did the wiping, then ran
`perform(refreshed)` on a still-nil window. That is the call that fired the
toast.

Corroborating: `kokoro.log` shows windows 246, 247 and 808 all reading empty
**within the same second** (15:03:25Z). One failure burst, not three faults.

Fix: `Iterm2SessionFetch { ok([Iterm2SessionInfo]), failed }` plus
`applyIterm2SessionFetch`, which drops a `.failed` pass and keeps the last good
mapping. `.ok([])` still clears, so a quit iTerm2 cannot pin a dead session id.
**All ten call sites had the bug**; all ten migrated.

## The same bug again, in the TTS path (`b9dbeec`)

`readContent` deliberately separates a failed AppleScript (`nil`) from an empty
buffer (`""`). `waitForStableContent` then threw that away with `?? ""` on both
read lines, so an unmapped window, a genuinely failed read, and a terminal with
nothing to say all produced one line:

> `TTS DROPPED … Suspect a revoked Automation/Accessibility grant`

Not vague — **wrong**. It sent the reader to System Settings instead of the
session map. `ContentSettleOutcome { stable, noSessionId, unreadable, empty }`
splits them, with `anyReadSucceeded` tracked rather than inferred from content,
because a successful read of an empty buffer is not a failed read.

Consequence worth recording: this message's history back to 2026-08-11 is
**not** evidence of a long-standing permissions fault. Much of it was probably
the unmapping bug.

Two side effects: an unmapped iTerm2 window now returns immediately instead of
burning the full 2.5s settle window proving there is nothing to target, and the
`skipStableWait` shortcut — which dropped failures silently — logs the same
three-way split.

## The generalisable lesson

**A function that returns a collection cannot report failure.** Every
`guard … else { return [] }` (or `?? ""`) over an I/O boundary is this defect
waiting for a caller that reads empty as authoritative. Two such callers existed
in this codebase and both were live bugs. A third pass over the remaining
AppleScript readers would be cheap and is not yet done.

## `injection.log` (`9a4ac75`)

The injector's only record of a failure was `print`, which reaches neither
`~/Library/Logs/Quip/` nor the unified log — verified: `log show --predicate
'process == "Quip"'` returns **zero lines** for a Quip launched from Finder. So
every "not yet mapped" and every TCC denial went on the floor, and "did the
keystrokes land?" was answerable only by looking at the user's screen.

```
DROPPED op=sendText window=com.googlecode.iterm2.808 app=iTerm2 kind=sessionNotFound msg="…"
```

`kind` is a closed vocabulary — `sessionNotFound | tccDenied | windowClosed |
unknown | unclassified` — so a stale session id (self-heals) greps apart from a
TCC denial (needs a human). Successes stay out; `latency.log` already has them
with timing. Six sites wired: the five iTerm2 session guards plus
`executeAppleScript`. Documented in `CLAUDE.md`.

## Install state

| Thing | State |
|---|---|
| `/Applications/Quip.app` | Release at `b9dbeec`, binary `Sep 11 10:24:49`. Signed `Developer ID Application: Fintech Adventures LLC (D2PM6R797Q)` at build time, `--verify --deep --strict` clean. Running pid `58103`, started `Sep 11 10:24:59`. |
| iOS device | **Untouched this session.** Every change was Mac-only; no reinstall was needed or done. Still the 2026-09-10 build at `aac4a1e`. |
| Stale copies | `/tmp/quip-release` and the DerivedData Debug copy unregistered from LaunchServices and deleted after each of the three installs. Only `/Applications/Quip.app` remains for `com.quip.mac`. |
| Working tree | pbxproj restored after every xcodegen run; only the pre-existing untracked `QuipMac/QuipMac.xcodeproj/xcshareddata/`. |

## Hardware-verified vs install-only

| Claim | Evidence |
|---|---|
| Desktop chips render with real counts | **Owner-confirmed on hardware** — This Desktop 10 / Other Desktops 2 / All Desktops 12. |
| The unmapping fix works end to end | **Confirmed on hardware.** `send_text` to window 808 at 17:17:25Z landed with no toast and no `injection.log` entry — same window, same path that failed before. |
| Phone authenticates over LAN | **Observed at last.** `client live: 192.168.4.42:54980 (auth=pin)` at 16:33:08Z. The 2026-09-10 handoff had this as never-seen. |
| `Iterm2SessionFetch` semantics | **Test-verified, proven non-vacuous.** Reverting the guard fails with `nil is not equal to Optional("UUID-808")` — the reported symptom exactly. |
| `ContentSettleOutcome` three-way split | **Test-verified.** 5 cases, including that `.empty` and `.unreadable` never compare equal. |
| `injection.log` line format | **Test-verified.** 6 cases via a pure static builder, including that a quote or newline in an AppleScript error is escaped rather than forging a second log line. |
| Full gate | **Green.** harness 62 checks, QuipMac 813 tests, QuipiOS 800 tests, `TEST SUCCEEDED` on all three. |
| `injection.log` actually writes | **NOT verified.** Format is unit-tested; the append path has never run, because nothing has failed since install. Created on first failure. |
| The new TTS diagnostics actually emit | **NOT verified.** Same reason. |
| Tapping a chip filters the grid, and tapping a card on another desktop switches Space and raises it | **STILL NOT verified** — carried unchanged from 2026-09-10. |

## Open threads

1. **Walk the chip interactions past the row.** The oldest open item, now two
   sessions old. The row renders with correct counts; untested are tapping
   "Other Desktops" to filter, tapping a card on another desktop to switch Space
   and raise it (`activate(options: [.activateAllWindows])` + AX raise), and
   returning via "All Desktops".
2. **Nothing is pushed.** 7 commits sit on local `eb-branch`.
3. **`injection.log` and the new TTS lines are unexercised.** First real failure
   proves both. To force one deliberately, send to a window id that no longer
   exists.
4. **Sweep the remaining AppleScript readers** for the same empty-means-failure
   shape. Two were found and fixed; nobody has checked the rest.
5. **Dual-path flap still appears.** A `CLOSE_WAIT` sat beside the live LAN
   socket at 16:33 and collapsed on its own. Related to
   `project_dual_path_reap_deadlock`; not chased.

## Resume in a fresh session

> Read `docs/superpowers/handoffs/2026-09-11-session-handoff.md`. The iTerm2
> unmapping bug is fixed and confirmed on hardware; start the tail of
> `~/Library/Logs/Quip/*.log`, check `netstat -an | grep 8765`, then walk the
> desktop-chip interactions past the row — filtering, and tapping a card that
> lives on another desktop.
