# Session handoff — 2026-09-13

## Header

| | |
|---|---|
| Branch | `eb-branch` |
| Tree | **Clean.** `git status --short` returns nothing. |
| Pushed | **`c149959`.** `git push origin eb-branch` moved `6863c30..c149959` (18 commits). `git rev-list --count origin/eb-branch..eb-branch` is now `0`. |
| Gate | `tools/check.sh --all`: **swiftc harness 62 checks / 0 failures · QuipMac 863 tests / 0 failures · QuipiOS 806 tests / 0 failures.** 3 suites ran, all green. **2 suites SKIPPED**: QuipLinux (cargo) and QuipAndroid (gradle), neither built on this machine. QuipiOS also ran without the QuipWatch target — no watchOS simulator runtime here. |
| Installed | `/Applications/Quip.app`, binary `Sep 12 13:44:04`, built from **`8c4f205`**. Running pid `81966` since `Sep 12 13:44:19`. |
| NOT installed | **`af86695` and `c149959` (both wand fixes) are committed and pushed but NOT in the running app.** The installed binary predates them. |
| iOS device | **Untouched all session.** Still the 2026-09-10 build at `aac4a1e`. `6727669`'s chip row has never run on hardware. |

Two other sessions committed to this branch concurrently (see **In progress**), so
roughly half the commits below are not mine. Authorship is marked.

## What shipped

Session span is `6dfad9b..HEAD`, 16 commits, 21 files, +2744 / −197.

| SHA | What it did | Mine? |
|---|---|---|
| `00d2f1e` | A failed AppleScript no longer unmaps every iTerm2 window. | yes |
| `9a4ac75` | Failed injections write `~/Library/Logs/Quip/injection.log`. | yes |
| `ac6348c` | Wishlist session log for the above. | yes |
| `b9dbeec` | A stale session map stops reporting itself as a permissions problem. | yes |
| `c4b107c` | Closed wishlist thread 5 — the TTS misdiagnosis was the same defect. | yes |
| `f5cd2fa` | 2026-09-11 session handoff. | yes |
| `6727669` | Phone: one collapsible 26pt filter row instead of two stacked ones. | yes |
| `50adedf` | A stale session id must not read as a quiet agent (adds the `sessionGoneSentinel`). | other |
| `f5b5a8c` | An unreadable window is not an unmapped window (adds `ContentRead`). | other |
| `d61d1f1` | Made the desktop/display filter row state its own rule. | other |
| `4610b7a` | Made `injection.log` parseable, complete and redacted; added `SESSION_FETCH` lines. | other |
| `e2234ae` | 2026-09-12 session handoff. | other |
| `ff9a4f8` | Made the sidebar wand configurable and able to rotate orders. | other |
| `8c4f205` | Stopped four more callers treating a failed read as empty content. | yes |
| `af86695` | Derived the wand's sort tier from the configured kinds. | yes |
| `c149959` | Stopped `.mostActive` presenting an alphabetical list as a ranking. | other |

### The one that mattered: `00d2f1e`

**Symptom.** The phone showed a red toast: `Text send failed: iTerm2 session not
yet mapped for window com.googlecode.iterm2.808`. Text would not send to a window
that was plainly open and on screen.

**What was tried and did not work.** The first two hypotheses were both wrong, and
both cost time:

1. *A Spaces regression from the previous session's `6863c30`.* Ruled out by
   measurement: iTerm2's `id of w` equals the CGWindowID for all nine live windows
   (808 included) with bounds matching to the pixel, so the Pass-1 join was sound.
2. *A revoked Automation/Accessibility grant.* `kokoro.log` said so in as many
   words — `Suspect a revoked Automation/Accessibility grant`. It was wrong; the
   grant was alive, subtitles and content reads were both working. **Chasing that
   message is the single biggest time sink available in this area**, which is why
   `b9dbeec` later rewrote it (see below).

Also tried and useless: `log show --predicate 'process == "Quip"'` to find the
injector's own diagnostics. It returns **zero lines** — see **Techniques**.

**Root cause.** `fetchIterm2SessionIds()` returned a bare `[Iterm2SessionInfo]`,
collapsing *"the AppleScript failed"* and *"iTerm2 has no windows"* into the same
value — `AppleScriptRunner.Output.failed` was computed and then discarded.
`applyIterm2SessionIds` opens by clearing **every** mapping before re-matching, so
a single timed-out AppleEvent unmapped all nine windows at once, and every send
failed until some later fetch happened to succeed. `ensureITermSessionResolved` —
written to *heal* exactly this — calls the same fetch, so a failed heal did the
wiping and then ran `perform(refreshed)` on a still-nil window. That is the call
that fired the toast.

The fix is `Iterm2SessionFetch { ok([Iterm2SessionInfo]), failed }` plus
`applyIterm2SessionFetch`, which drops a `.failed` pass and keeps the last good
mapping. `.ok([])` still clears, so a quit iTerm2 cannot pin a dead session id.
All ten call sites were migrated.

**It is confirmed working in production.** `~/Library/Logs/Quip/injection.log`
carries **10** lines of `SESSION_FETCH failed streak=1 action=kept-last-good-mapping`
between `2026-09-12T15:45:31Z` and `2026-09-13T16:54:48Z`. Each of those is an
AppleEvent failure that would previously have unmapped every window.

**The generalisable lesson, which paid off twice more in the same session:** *a
function that returns a collection cannot report failure.* Every
`guard … else { return [] }` or `?? ""` across an I/O boundary is this defect
waiting for a caller that reads empty as authoritative. `b9dbeec` and `8c4f205`
are both the same bug found by looking for that shape.

## New test surface

| File | What it would catch |
|---|---|
| `Shared/Tests/WindowManagerSessionIdTests.swift` | A failed session fetch wiping good mappings; a genuinely-empty fetch failing to clear a dead session id. Proven non-vacuous — reverting the guard fails with `("nil") is not equal to ("Optional("UUID-808")")`. |
| `QuipMac/Tests/ContentSettleOutcomeTests.swift` | `.empty` and `.unreadable` collapsing back into one another; content failing to win over a stale `sessionGone` signal. |
| `QuipMac/Tests/InjectionLogTests.swift` | An AppleScript error containing a quote or newline forging a second `injection.log` line; the `kind` vocabulary leaking an associated value; a space-carrying `op` breaking the field grammar. |
| `QuipMac/Tests/WandSortTests.swift` | The wand's sort ignoring the configured target kinds. Proven non-vacuous — restoring the old fixed table fails 5 of the 6 new cases. |
| `Shared/Tests/MessageProtocolTests.swift` | The collapsed desktop chip naming a filter the grid is not applying. Proven non-vacuous — stubbing `collapsedTitle` fails with `("All Desktops") is not equal to ("space-3")`. |

## In progress

**Nothing uncommitted.** `git status --short` is empty, nothing stashed, no
half-finished branches.

But two things the next session must know:

1. **At least one other session was editing this repo concurrently, and may still
   be.** `QuipMac/Models/WandSort.swift` changed under me three times mid-edit —
   `WandTargetKinds.ordered` and `kind(bundleId:targetKind:)` appeared, then were
   deleted, while `git status` flipped between clean and modified. I stopped
   editing that file rather than fight it. **Check `git log --oneline -5` and the
   mtime of `WandSort.swift` before touching it.**
2. **`af86695` contains code I did not write.** `WandTargetKinds.ordered` and the
   `kind(bundleId:targetKind:)` classifier were on disk from another session when
   I staged, and were swept into my commit. That commit message claims broader
   authorship than is accurate. The other session has since deleted both helpers.
   Nothing is broken — the gate is green — but do not treat that message as a
   record of who designed what.

## Next steps

1. **Fix the wand Settings checkboxes.** The user reported, and I confirmed in the
   code, that unchecking the last box under "Switches on" makes all three snap
   back. `WandSection.kindToggle` (`QuipMac/Views/SettingsView.swift:932-945`)
   writes `next.rawValue`, which is `0` at the last uncheck; the getter's
   `WandTargetKinds.fromStored` maps `0` back to `.default`. The write lands, the
   read undoes it. `modeBinding` (`:947+`) has the identical shape via
   `WandSortMode.rotation(fromStored: "")` returning `allCases`.
   **I did not fix this** — the concurrent editor had `WandSort.swift` open.
   Start: `grep -n "kindToggle\|modeBinding" QuipMac/Views/SettingsView.swift`
   *Proves:* the empty state is unrepresentable rather than silently corrected.
   *Cannot prove:* that the user understands *why* the box won't turn off —
   `.disabled(...)` alone is mute; pair it with `.help(...)`.
   Note `fromStored`'s current doc comment already **claims** "The Settings UI
   refuses to let the last kind be unchecked". It does not. Same defect one layer
   up: a comment asserting behaviour the code lacks.

2. **Install the Mac app so `af86695` and `c149959` actually run.**
   Start: follow `reference_quip_install_recipe` — Release build, verify
   signature, `ditto` into `/Applications`, confirm a fresh pid.
   *Proves:* the wand changes are live. *Cannot prove:* anything about the phone.

3. **Install the iOS app and walk the chip row.** `6727669` has never run on
   hardware. The `.app` was built this session at
   `/tmp/quip-ios/Build/Products/Debug-iphoneos/Quip.app` — **that path is gone**,
   `/tmp` was cleaned; rebuild.
   Start: see **Techniques** for the watch-free build incantation.
   *Proves:* the merged 26pt row renders and collapses. *Cannot prove:* the
   cross-desktop raise, which needs a second desktop with windows on it.

4. **Walk the desktop-chip interactions past the row.** Open since 2026-09-10 and
   still unwalked: tap "Other Desktops" and confirm the grid filters; tap a card
   on another desktop and confirm macOS switches Space and raises it
   (`activate(options: [.activateAllWindows])` + AX raise); tap "All Desktops".
   *Proves:* the feature end to end. *Cannot prove:* anything without a human
   holding the phone.

## Blockers

**Waiting on a human:**

- **The iPhone is unreachable.** `xcrun devicectl list devices` shows all three
  devices `unavailable`; an install attempt returned
  `ERROR: CoreDeviceService was unable to locate a device matching the requested
  device identifier.` `netstat -an | grep 8765` shows no ESTABLISHED socket.
  **Action:** plug the phone in, or unlock it on the same network, then
  `xcrun devicectl list devices` should show it `connected`.
- **"App seems to be crashing" — never diagnosed.** Raised 2026-09-11 and parked.
  I established the *Mac* app was not crashing (same pid throughout, zero
  `Quip_*.ips` reports that day — newest were `2026-09-08`, no `.hang` files). The
  wire showed the phone re-authenticating six times in ten minutes with
  `POSIX 57: Socket is not connected` arriving in the same second as `client live`.
  **Action:** the user needs to say what they actually saw — the iPhone app
  quitting to the home screen, or the Mac menu-bar icon vanishing. The logs cannot
  distinguish these.
- **A concurrent editor may still hold `WandSort.swift`.** **Action:** confirm
  with the user which session owns the wand work before editing that file.

**Waiting on code / environment:**

- **`injection.log` has still never recorded an injection failure.** The file now
  exists with 31 lines, but **zero** match `DROPPED op=`; all 31 are
  `SESSION_FETCH` lines from `4610b7a`. The `DROPPED` append path remains
  unexercised. To force one deliberately, send to a window id that no longer
  exists.
- **No watchOS simulator runtime on this Mac**, so `-scheme QuipiOS` hard-fails.
  `tools/check.sh` works around it; a bare `xcodebuild` does not. See
  **Techniques**.

## Techniques worth not re-deriving

- **`print` in QuipMac reaches nothing.** `log show --predicate 'process == "Quip"'`
  returns **zero lines** for a Quip launched from Finder — measured, not assumed.
  Any diagnostic you want to read later must go through `LogPaths` into
  `~/Library/Logs/Quip/`. This is why `injection.log` exists.
- **A bare `xcodebuild` on QuipMac fails with `cannot find type 'DisplayGeometry'
  in scope`** (US-005: `Shared/` files missing from the committed pbxproj). Run
  `cd QuipMac && xcodegen generate` first, then **`git checkout
  QuipMac/QuipMac.xcodeproj/project.pbxproj`** afterwards to keep the tree clean.
  `tools/check.sh` does this for you; direct `xcodebuild` does not.
- **Building QuipiOS by hand needs a watch-free spec.** `-scheme QuipiOS` fails
  with `watchOS 26.5 must be installed`. Generate `project.nowatch.yml` with the
  python block in `tools/check.sh:141-168` (`ios_generate`), run
  `xcodegen generate --spec project.nowatch.yml`, build, then delete the spec and
  `git checkout QuipiOS/QuipiOS.xcodeproj/project.pbxproj`. The spec must outlive
  the build — xcodegen records its path inside the project.
- **`Mach error -308 - (ipc/mig) server died` from the QuipiOS suite is a
  simulator crash, not a test failure.** It happened once this session under
  memory pressure (the system also killed a background `tail`). `xcrun simctl
  shutdown all` and re-run; it came back 806/806 green. **Do not report this as a
  failing gate without re-running.**
- **`nm` and `strings` are unreliable oracles for "is my code in this binary".**
  A Release build strips helper symbols, and a control string known to be in the
  old code (`qa-mode.log`) also read zero. Trust instead: the build succeeded from
  the committed tree, `ditto` ran, `codesign --verify --deep --strict` passed, and
  the process has a **fresh pid**.
- **Quip traps SIGTERM.** `osascript -e 'quit app "Quip"'` and `killall` can both
  no-op. Always verify a fresh `STARTED` time with `ps -o pid,lstart`; use
  `killall -KILL Quip` if stale.
- **Measure the mapping before blaming the mapper.** The decisive evidence in
  `00d2f1e` was running iTerm2's own session script by hand and comparing `id of w`
  against `CGWindowListCopyWindowInfo`. They matched exactly, which eliminated two
  hypotheses in one command.

## Files to know

| Path | Why |
|---|---|
| `QuipMac/Services/WindowManager.swift` | `fetchIterm2SessionIds` / `applyIterm2SessionFetch` — the session map, and the origin of the session's main bug. `applyIterm2SessionIds` still clears before re-matching; that is deliberate and only safe because `.failed` never reaches it. |
| `QuipMac/Services/KeystrokeInjector.swift` | `readContent` / `readContentDetailed` / `ContentRead`. Prefer `readContentDetailed` in new code — the `String?` wrapper is the lossy one that caused two bugs. |
| `QuipMac/QuipMacApp.swift` | `ContentSettleOutcome` (~line 110), `waitForStableContent`, `triggerTTSFor`, and the four read call sites fixed in `8c4f205`. |
| `QuipMac/Models/WandSort.swift` | Wand ordering + `WandTargetKinds`. **Contested — another session was editing it.** |
| `QuipMac/Views/SettingsView.swift` | `WandSection` at ~line 893; the unfixed checkbox bug at `:932-945`. Untouched by the concurrent editor as of `Sep 12 13:21`. |
| `QuipiOS/QuipApp.swift` | `filterChips` / `spaceChipGroup` / `screenChip` (~line 3700) — the merged filter row. `MainiOSView` starts at ~1343; note `QuipApp` and `MainiOSView` both hold space state, and putting `@State` in the wrong one costs a build. |
| `tools/check.sh` | The gate. `ios_generate()` at `:141` is the watch-free spec recipe. |
| `~/Library/Logs/Quip/injection.log` | `SESSION_FETCH` lines prove `00d2f1e` is working in production. No `DROPPED` line has ever been written. |
