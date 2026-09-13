# Session handoff — 2026-09-12

## What was asked

A code review of the pending changes on `eb-branch` — the eight unpushed commits
from the 2026-09-11 session — with instructions to flag only what a careful
maintainer would block on. Five findings came back. The user then said "fix
findings 1 and 2", later "go" for the rest, and mid-turn pivoted with:

> the mulple screens / monitors / dekstops is confusing

So the session is two halves: closing out the review of yesterday's iTerm2 work,
and a UX fix on the phone's filter row that the user raised directly.

## Commits

| Hash | Why |
|---|---|
| `50adedf` | `fix(iterm2)` — a stale session id was being reported as "the agent had nothing to say". Review finding 1. |
| `f5b5a8c` | `fix(iterm2)` — the per-window `try` still unmapped windows; `.failed` only ever covered whole-script failure. Review finding 2. |
| `d61d1f1` | `fix(phone)` — the desktop/display chip row now states its own rule: counts scoped to the other filter, named resets, combined empty state. The user's "confusing" report. |
| `4610b7a` | `fix(diagnostics)` — `injection.log` made parseable, complete and redacted; the dropped session fetch is no longer silent. Review findings 3, 4 and 5. |

`6727669` (`feat(chips): one collapsible filter row instead of two stacked ones`)
sits between yesterday's handoff and `50adedf`. It was **not** made in this
session — it was already on the branch when the first commit landed. Whoever
made it, `d61d1f1` builds directly on it.

`eb-branch` is **13 commits ahead of `origin/eb-branch`** and has **not** been
pushed. Per standing policy, pushing needs an explicit go-ahead.

## The review

Five findings, all verified against the code rather than inferred. Two were
merge-blockers, three were the lower tier. All five are now fixed.

### 1. A stale session id read as a quiet agent (`50adedf`)

Yesterday's `b9dbeec` split the settle-window outcome three ways so that "we
could not look" stopped being reported as "the agent stayed quiet". The split
was correct and still missed the case it most needed to catch.

`readContent`'s iTerm2 script walks window → tab → session looking for the cached
UUID. When the walk found nothing it fell off the end and returned `""` — a
**successful** AppleScript run. So `result.failed` was false, `anyReadSucceeded`
stayed true, and the new classifier landed on `.empty`:

```
TTS skipped for <id>: reads succeeded but the buffer stayed empty — the agent had nothing to say.
```

A session recreated under us — the exact failure the self-heal path exists for —
was therefore reported as a healthy quiet terminal. One confident misdiagnosis
traded for another.

The walk-miss now returns `KeystrokeInjector.sessionGoneSentinel`, matched
against the **raw** output before trimming and redaction, whole-string only.
`readContentDetailed` reports `.ok(String)` / `.failed` / `.sessionGone`;
`readContent` keeps its `String?` shape for the twelve callers that only want
content, mapping both failure cases to nil.

That nil has a second effect worth knowing about: `TerminalStateDetector`'s
prompt-raise gate takes two pane reads and compares them. A dead session used to
give it two matching empty strings — `.stable` — and it confirmed a raise on a
pane it could not read. It now sees `.unreadable` and raises on CPU alone, which
is the honest fallback it already had.

`ContentSettleOutcome` gained `.sessionGone`. It outranks `.unreadable` on empty
content and loses to real content, so a session that heals mid-window is not
reported gone.

New `healIterm2SessionMap(triggeredBy:)` kicks a refresh.
`ensureITermSessionResolved` only ever covered windows whose id is **nil**, so a
window holding a non-nil id that no longer resolves never reached it and stayed
stale until an unrelated poll happened to fix it. The heal is coalesced to one
fetch in flight app-wide — a dead session is rediscovered by every 2s poll on
every tracked window, and each would otherwise queue an AppleScript ahead of the
keystrokes the user is waiting on.

### 2. An unreadable window is not an unmapped window (`f5b5a8c`)

Yesterday's `00d2f1e` stopped a failed AppleScript from unmapping every window.
It covered whole-script failure only, and the same defect survived through the
mechanism that makes the script robust.

Each window's body is wrapped in `try … end try` so one bad window cannot abort
the repeat. A window that threw simply produced no row — and the apply side
opens by clearing every iTerm2 mapping before re-matching, so a missing row read
as "this window has no session". Per-window scale, same bug. With every window
throwing, the result was `.ok([])`, which sailed past the new guard and wiped
everything.

The catch now reports instead of swallowing: `ERROR\t<wid>`, with `wid` seeded to
`-1` before the `try` so a window that fails at `id of w` names nothing and
forces the whole pass to `.failed`. A `COUNT` header separates "iTerm2 has no
windows" (clear — correct, otherwise a dead id gets pinned forever) from "we read
nothing from N windows" (`.failed`).

`Iterm2SessionFetch.ok` now carries `unreadableWindows:`, and
`applyIterm2SessionIds(_:preserving:)` leaves those windows exactly as they were,
claiming their uuids up front so the Pass-2 bounds fallback cannot hand a
preserved session to a co-located window.

### 3–5. injection.log (`4610b7a`)

Three defects in yesterday's `9a4ac75`, all on `executeAppleScript` — the path
every classified failure takes, TCC denials included.

- **Grammar.** It passed its whole prose context down as `op`, producing
  `op=sendText to com.googlecode.iterm2.808 [iTerm2]`. Any reader splitting on
  whitespace to reach `window=` or `app=` got garbage, on exactly the lines the
  file exists to make greppable. The pre-flight `sessionNotFound` guards were the
  only ones with a clean op, and those were already the easy failures.
- **Missing data.** It hardcoded `window="-"` and `app=nil` while all thirteen
  call sites had both in hand. They are parameters now; what does not fit a bare
  token (spawn directory, command, keystroke + AppleScript expression) moved to a
  quoted, escaped `detail=` field. Tokens are sanitised on emit.
- **Redaction.** `message` and `detail` now pass through `SecretRedactor`. An
  AppleScript runtime error can echo the offending expression back, and the send
  scripts embed the user's own text in their source — so the file could
  accumulate prompt content in plaintext under a path that survives reboots and
  is indexed by Console.app.

Plus the silent drop from finding 2's fix. Keeping the last good mapping when a
fetch fails is right; doing it without a word means a persistently failing fetch
is indistinguishable from a healthy system while every send runs against ids
nothing is refreshing. `SESSION_FETCH` lines now record the failure streak
(throttled: first, then every 30th — the poll is 2s), the recovery, and which
windows deliberately kept an older mapping.

`CLAUDE.md` documents the full grammar. The xcodegen-generated scheme
directories are now gitignored.

## The chip row (`d61d1f1`)

The user was asked which of four confusions they meant and picked three:
counts not matching the grid, unclear rules between the two filters, and the
desktop/screen/monitor wording. They explicitly did **not** pick "grid shows
wrong windows", so the Spaces/display assignment itself is believed correct.

- **Counts.** Every chip counted against the full window list, ignoring the other
  filter. Pin a desktop and the display chips still reported per-monitor totals,
  so the badges did not sum to the cards on screen and nothing hinted the other
  axis was the reason. Counts are now scoped to what the other side allows, which
  makes the AND visible: the badges *are* the rule, and a `0` says "nothing here,
  given the other filter".
- **Rules.** The display reset read `All` next to the desktop group's
  `All Desktops`, so the unqualified one looked like a whole-row reset. It is now
  `All Displays`, and an empty grid offers one **Show everything** that clears
  both axes.
- **Empty state.** It fired only for a pinned display. A desktop filter that
  emptied the grid rendered a blank canvas that looked like a dead connection —
  precisely when the reader most needs telling that two filters combine. It now
  names every active filter.
- **Wording.** A Space is a "desktop", a monitor is a "display", and "screen" is
  left to the parts that really mean screen geometry. `screenChip` → `filterChip`
  (both axes use it), `screenFilteredWindows` → `filteredWindows` (never
  display-only).

One deliberate non-change: the desktop chips still come from the **full** window
list, not the display filter's survivors. A filter row that reshuffles itself as
you use it is worse than a stable one showing a zero. Worth revisiting if the
user disagrees on hardware.

## Verified vs install-only

| Thing | Status |
|---|---|
| QuipMac suite (828 tests) | **Green.** Ran signed, Quip quit first. Includes 6 new `InjectionLogTests` and 4 new session-map tests. |
| QuipiOS suite (806 tests) | **Green**, via the watch-free spec. |
| swiftc harness (62 checks) | **Green.** |
| Mac `/Applications/Quip.app` | **Installed**, Release, Developer ID `D2PM6R797Q` signed at build time, ditto'd, relaunched. Verified by `nm` symbol (`sessionGone`), not mtime — ditto keeps the bundle dir's old date. `mdfind` confirms it is the only `com.quip.mac` on disk. |
| Mac behaviour on hardware | **NOT verified.** No `.sessionGone` line, no `SESSION_FETCH` line, no new-format `DROPPED` line has been seen in a real log. All four fixes are test-and-compile verified only. |
| iOS app on a device | **NOT installed.** Neither phone would take it — see below. |
| Chip row on hardware | **NOT verified.** The phone still runs the old bundle. |

## Open threads

1. **iOS install is blocked on the devices, not on the build.**
   The device build is done and waiting at
   `QuipiOS/build/Debug-iphoneos/Quip.app` (Watch app embedded, signed
   `D2PM6R797Q`).
   - iPhone 17 Pro Max (`FA951BBB-D706-5FCF-9886-3E57560E9030`) — `unavailable`
     in `devicectl list devices` for the whole session.
   - iPhone 12 / Work 📲 313 (`57D2BBCF-26AB-57DB-8FCF-38E910BC2BF3`) — tunnel
     connects, then
     `ERROR: The operation failed because Developer Mode is disabled. (com.apple.dt.CoreDeviceError error 10005)`.
     Needs a tap on the device: Settings → Privacy & Security → Developer Mode,
     then a restart.

   Note the app landed in the **legacy** `QuipiOS/build/` location. `-scheme
   QuipiOS` hard-fails on this Mac (`watchOS 26.5 must be installed in order to
   run the scheme` — the known missing simulator-runtime gap), so it was built
   with `-target QuipiOS`. The Watch app is still embedded, since it is a target
   dependency.

2. **Nothing from today has been exercised on hardware.** The acceptance flows
   that would close that out:
   - Recreate an iTerm2 session under a tracked window (kill the pane, open a
     new one in place) and confirm `kokoro.log` says the session id no longer
     resolves rather than "the agent had nothing to say", and that the map heals
     without a restart.
   - Open a hotkey/utility iTerm2 window alongside the tracked ones and confirm
     `injection.log` shows `SESSION_FETCH partial unreadable=…` while the other
     windows keep sending.
   - Force a TCC denial and confirm the `DROPPED` line parses — `op` a bare
     token, `window` and `app` populated, context in `detail`.
   - On the phone: pin a desktop and a display together, check the badges sum to
     the visible cards, and that an empty combination offers **Show everything**.

3. **Mac TCC grants may need re-granting.** The Mac was rebuilt and reinstalled
   this session. Accessibility and Screen Recording can drop even with stable
   signing.

4. **13 commits unpushed.** Standing policy: no push without an explicit
   go-ahead.

## Resuming

> Read `docs/superpowers/handoffs/2026-09-12-session-handoff.md`, then get
> `QuipiOS/build/Debug-iphoneos/Quip.app` onto a phone and walk the four
> hardware acceptance flows in "Open threads" item 2.
