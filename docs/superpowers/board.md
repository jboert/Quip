# Quip board

Working branch: `eb-branch` (long-lived; see the branch policy note at the bottom).
Source of truth for context on each item: `docs/superpowers/wishlist.md`.

Lives here, not in `tasks/` — that directory is gitignored (ralph-loop artifacts),
so a board written there is invisible to the next session and to anyone else.

Status: `ready` (picked up in priority order) · `in progress` · `blocked` · `done`.

## In progress

_(none)_

## Ready

| ID | Title | Notes |
|----|-------|-------|
| Q-17a | §58 Iteration 2 manual smoke | IN PROGRESS 2026-08-19 — Mac + iOS both installed, phone connected over Tailscale, live tail armed. Create / edit / delete a prompt from the phone, save while in Airplane Mode, and try a name that sanitizes to an existing filename. |
| Q-19b | Drag-to-resize smoke | Unblocked 2026-08-19 (Mac install done, pid 42368). Toggle on, drag a tile corner, Arrange, confirm the window matches the dragged rect; switch preset and confirm sizes reset. |
| Q-16 | §58 Iteration 3 manual smoke | Unblocked 2026-08-19 (Mac install done). Close tracked iTerm windows during active polling, confirm no stale state or source churn. NOTE: the 2026-08-18 attempt proved nothing — the window opened for it never entered a tracked state, so the clean log meant nothing ran. Use a window actually running an agent CLI and confirm it is tracked first. |
| Q-18a | §58 Iteration 1 manual smoke | Partly unblocked 2026-08-19. Runnable half: reorder in the layout preview, confirm sidebar + Arrange agree. Multi-display half stays BLOCKED — this machine has one display. |
| Q-34 | Prompt variables | `{{file}}`, `{{branch}}`, `{{cwd}}`, `{{selection}}`-style placeholders in a prompt body, filled from the target window at send time. The Mac knows the window's cwd and git state; the phone does not, so expansion belongs on the Mac in the `paste_prompt` handler, with a preview of the expanded text on the phone. Undefined variable: send it literally, never block. Requested 2026-10-01. |
| Q-35 | Prompt generator uses usage data | `PromptGeneratorSheet` drafts new prompts with no idea what the user actually fires. Feed it the top `PromptRanker` prompts for the selected window's agent as examples, so drafts match the user's habits. Requested 2026-10-01; depends on Q-33. |
| Q-33a | Prompt ranking on hardware | Install iOS, fire the same prompt a few times in a Claude window and once in a Codex window, then open the picker in each. The Claude-heavy prompt should lead in Claude windows only. The backup reaches the Mac only after the next Mac install (Shared/ schema field), so check the restore after that. |
| Q-27 | Duplicate prompts — reported, NOT reproduced | Both latent paths FIXED (Q-27a sync, Q-27b pack re-import). What remains is the reported case itself: it has never been reproduced, so a screenshot of a real duplicate pair is still wanted before closing. |

## Blocked

| ID | Title | Blocked on |
|----|-------|-----------|
| Q-36 | "I want to be able to pin a bomb" | A dictated request, 2026-10-01. The owner said it does NOT mean pinning a prompt. Windows can already be pinned (`1999bd9`). Needs the owner to say what "bomb" was before any work. |
| Q-32a | First TestFlight upload | Needs an App Store Connect app record, which Apple only lets you create on the website: New App, iOS, name **Quip Remote**, bundle ID **com.fintechadventures.quip** (team D2PM6R797Q). Then `QUIP_ASC_KEY_ID=… QUIP_ASC_ISSUER_ID=… tools/testflight.sh`. The signing dry run (`--no-upload`) already passes. |
| Q-18a-multi | §58 Iteration 1 multi-display pass | Needs a second monitor — this machine has one display. |
| Q-25 | Hardware acceptance for the 2026-09-16 grid work | Phone unreachable since 2026-09-13 (`tunnelState: unavailable`); Mac app is still 1.5.5 from Sep 13. Nothing from that session has run on hardware. Two checks: filter row absent with the Labs flag off and no window missing a card; canvas at true aspect on the ultrawide. If the band reads too short, one line in `hostScreenRect` reverts it. |

## Done

| ID | Title | Landed |
|----|-------|--------|
| Q-37 | `tools/check.sh`: a suite whose simulator refused to launch the test host (`Busy ("Application failed preflight checks")`) printed a bare `TEST FAILED`, which read as a code failure. Found when the Q-33 pre-commit went red on a tree that was green twice before. `summarize_suite_log` now names the simulator, quotes the `Failure Reason` once, and prints the reboot command. A green suite that xcodebuild retried past stays quiet | verified 2026-10-01 — 5 new check-script assertions (`bash tools/run-check-script-tests.sh`: 15 passed); removing the detection failed 4, removing the green-suite guard failed 1; gate green |
| Q-33 | The prompt picker ranks by frecency, not by last use. Last-use order put one stray tap above a prompt fired every day. `Shared/PromptRanker.swift`: each use adds 1 to a score that halves every 7 days, so a prompt holds its place only by being used, and an old habit fades. A use in the selected window's agent (Claude, Codex, shell…) counts 2x more there, so each agent gets its own order. The old last-use map migrates on first read with its order intact. Usage now rides `PreferencesSnapshot.promptUsageJSON` to the Mac and is merged on restore, not overwritten. Before, usage was phone-only and a reinstall lost it | verified 2026-10-01 — 11 new `PromptRankerTests`; a mutation zeroing the context weight failed 1; 950 Mac / 876 iOS green. Hardware check owed (Q-33a) |
| Q-32 | TestFlight pipeline: `tools/testflight.sh` archives, exports an App Store IPA and uploads it with an App Store Connect API key (`--no-upload` for a signing dry run). The first dry run found three release blockers, all fixed: (1) the watch app was hardcoded to `com.quip.QuipiOS.watchkitapp` with companion `com.quip.QuipiOS` while the phone app builds as `com.fintechadventures.quip`, so the watch could never pair and the upload would be rejected; every target now derives from one `QUIP_APP_BUNDLE_ID`; (2) `SKIP_INSTALL: NO` on the watch and Live Activity made a Generic Xcode Archive that cannot be exported; (3) CFBundleVersion was hardcoded to `1` and the watch said 1.4.0 against the app's 1.5.6; all three targets now share `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | verified 2026-09-27 — dry run exported a signed IPA: app + embedded watch both `1.5.6 (202609271119)`, IDs `com.fintechadventures.quip[.watchkitapp]`, `aps-environment` production; 865 iOS tests green. Upload blocked on Q-32a |
| Q-22 | Focus resolves the window on public API only (owner decision defaulted to the no-private-API route, 2026-09-26): live CG bounds re-read at tap time, then position → size → exact title; title + size fallback for a window moved since the poll or with no readable AX position; still-identical candidates are REFUSED and logged instead of raising the first | verified 2026-09-26 — 8 new `AXWindowMatchTests` (incl. two same-origin candidates resolving to the second); mutation disabling size/title narrowing failed 2; 938 Mac tests green. Hardware re-measure of the 5/11 desk still owed |
| Q-31 | `tools/check.sh` can no longer hang: every Xcode suite runs under `run_bounded` (pure bash, default 1200s, `QUIP_CHECK_SUITE_TIMEOUT` overrides). A timed-out suite is killed along with its children, reported as TIMED OUT with the simulator reboot command, and counted as a failure. Found a watchdog race on the way (a retired watchdog could mark a finished command as timed out), fixed and covered | verified 2026-09-26 — 4 new behavioral check-script tests, 5 clean runs; `--all` green; a real 4s timeout killed xcodebuild, exited 1, and left no processes |
| Q-27b | Importing the same `.quippack` twice no longer duplicates it. A prompt already installed (same label + body, any id) and a button already installed (same label, icon and payload) are skipped. Changed content under a taken id is still added with a suffix, never overwritten. The import sheet says how many will be skipped, and Import is disabled when nothing is new | verified 2026-09-25 — 5 new tests; a mutation disabling the skip failed 4 of them; 865 iOS tests green |
| Q-30 | `tools/check.sh` on a red suite printed only "Executed N tests, with 5 failures" — `grep | tail -3` cut every line naming the failing test. Failing `error:` lines now print first (deduped, capped at 15) and runtime os_log noise like `[sandbox] … (error: -9)` no longer matches | verified 2026-09-25 — fixture check + full gate green |
| Q-27a | VibeCut sync: two prompts with the same name AND same body mapped to two identical-looking rows differing only by an id suffix. They now collapse to one entry (tags unioned) and count toward `skipped`, so the ack's synced count equals the rows shown | verified 2026-09-25 — 4 new mapper tests (3 red first) + 930 Mac / 860 iOS / 62 harness green |
| Q-29 | Mobile Broadcast Prompt promoted to a full-width primary action above the main controls, with a compact landscape treatment and terminal-aware disabled state | verified 2026-09-23 — mutation check + 856 iOS tests + full gate green |
| Q-28 | Mobile Broadcast Prompt sheet — draft/library input, terminal-only multi-select, safe ordered fan-out, and failed-target-only retry | verified 2026-09-23 — 5 focused tests + 855 iOS tests + full gate green |
| Q-26 | `MainiOSView.body` split into stages — `rootLayers` / `contentWithOverlays` / `contentWithLifecycle` / `contentWithSheets` plus the two big overlay closures, each type-checking on its own. Modifier order unchanged | `e05b066` |
| Q-24 | Wand: unchecking a kind switches it OFF instead of hiding it from the wand — the checked set is now the selection, idempotent | `7c8921f` |
| Q-22a | A focus that finds nothing now says so — `.none` and `.ambiguous` are logged with the wanted origin and the AX positions actually seen, throttled per window id | `a7e6125` |
| Q-23 | A minimized window is unminimized before the raise — `kAXRaiseAction` alone never restores from the Dock | `a7e6125` |
| Q-0a | Multi-select submits every pick instead of untoggling the last one | `2c57768` |
| Q-0b | Trailing Return no longer answers the next prompt; window we read is the window we answer | `2dec128` |
| Q-0c | Terminal.app reads target the requested window (its AppleScript window id IS the CGWindowID) | `b9664e4` |
| Q-1 | Correct the stale §18.2 "keystroke assumption UNVERIFIED" note — it guessed wrong and is now measured | `9ab3c93` |
| Q-2 | Live Claude widget shapes locked in the iOS detector suite (7 tests, 738 green) | `51df71d` |
| Q-5 | `APNsJWTTests` hang retired — re-measured, no longer reproduces; latent default-argument hazard documented | `7c7fcba` |
| Q-3 | Codex image upload under Terminal.app falls back to the typed path instead of hard-failing | `7cf350a` |
| Q-4 | Image paste offers TIFF + PNG + file URL instead of TIFF alone | `e6c1d90` |
| Q-6a | A divider under the options closes the menu — "Chat about this" is no longer a chip | `ec9308b` |
| Q-7 | All 10 open swallowed-error sites closed (8 fixed, 2 already fixed and the audit was stale) | `01c7657` |
| Q-8 | CI stops starting 10x-billed macOS runners for changes that cannot affect Swift | `f19760d` |
| Q-9 | `tools/check.sh` — local gate runs only the suites a change can affect, sharing CI's mapping | `7e1c029` |
| Q-6b | The widget's free-text row ("Type something") is no longer offered as a chip — rule read out of the shipped CLI binary, not guessed at | `aea89d0` |
| Q-10 | `pre-commit` runs the gate on staged paths; fixed the gate reporting a failing swiftc harness as green (`\| tail` masked its exit status) | `b994d97` |
| Q-11 | Three more places where a failure read as success: CI's `changes` job failed CLOSED (a broken mapper silently skipped both macOS jobs), the hook installer reported "installed" after a failed `ln`, and the Mac smoke test called an unreadable log store a pass | `ba07665` |
| Q-12 | `check.sh`'s `.github/` rule was a fallback, so a CI change shipped alongside a `tools/` change was verified by a 2-second swiftc run | `38482d9` |
| Q-14b | Multi-select verified phone→Mac end to end (`select_multi:1,2`, correct picks) — closes the old Q-A1 | verified 2026-08-17 |
| Q-15 | Pre-handshake reaper — probe sockets no longer leak, no more false "broke during handshake" WARNs | `1dbd64b` |
| Q-16a | LAN routing — swap engine was default-off for everyone and compared probes against live round-trips | `58dd75e` |
| Q-16b | §58 Iteration 3 — terminal poll generation, coalescing, stale-result guards | `0a1b206` |
| Q-17 | §58 Iteration 2 — prompt mutation trust. Acks/pending UI/metadata had landed earlier; the last gap was client-side id validation, now a shared sanitizer with a filename preview and a collision warning | `316f483` |
| Q-19 | §58 Iteration 4 — drag-to-resize now real: 8 handles per tile, Arrange uses the dragged rects, presets reset them | `198b43c` |
| Q-19a | §58 Iteration 4 — spawn-path quoting, accessibility labels, protocol docs | `f42ae84` |
| Q-18 | §58 Iteration 1 — one order source for sidebar/preview/arrange, Arrange targets the selected display in AX coordinates, failures surface instead of doing nothing, row numbers mean arrange slots | `cf0f1b3` |
| Q-20 | Terminal state flaps ~26×/min — enter/exit debounce is now asymmetric: raising a "waiting for input" badge needs 1.5s of sustained quiet, clearing one still takes 0.5s | `9aef9f8` |
| Q-13 | CI had failed at step one on every run since `f19760d`: an unanchored `scripts/` in `.gitignore` matches at ANY depth, so `.github/scripts/` was never committed and the workflow called two files that do not exist on a runner | `889db83` |
| Q-20a | Flap measured on hardware after install — reduced ~26/min to ~14.7/min, but did NOT reach the single-digit bar; root cause found and refiled as Q-21 | measured 2026-08-19 |
| Q-21 | Terminal "waiting for input" was inferred from CPU alone, so an agent blocked on an LLM stream read as a prompt. The raise now re-reads the pane twice 400ms apart and proceeds only if nothing moved | `7611d32` |
| Q-21a | Prompt gate confirmed on hardware — raises across all windows 67 -> 10 in the same 180s protocol, worst window 44 -> 1, zero fail-open skips | measured 2026-08-19 |
| Q-14 | Main-thread blocking sweep: PTT chunk decode, WebSocket broadcast encode, and the VibeCut packs read moved off main; a dead AX walk deleted. Three sites left alone with reasons (see wishlist) | `05b935a` |

## Branch policy

Work stays on `eb-branch`. Merging to `main` and pushing to GitHub are **not**
automatic here: the repo owner has a standing rule that every push needs
explicit per-push confirmation. Finished work is committed on `eb-branch` and
reported; the merge-back is the owner's call.

Two things about that merge-back, both established 2026-08-06:

- **PR #29 is MERGED, not open.** An earlier note here said it was open and
  that main-conflicting operations were therefore unsafe. `gh pr list --state
  open` returns `[]`. That caveat no longer applies to anything.
- **`main` is a protected branch and rejects direct pushes** — "Changes must be
  made through a pull request" (`protected branch hook declined`). The merge
  itself is a clean fast-forward and has been run locally: local `main` is at
  `889db83`, `origin/main` at `3269351`. Landing it needs `eb-branch` pushed and
  a PR opened, which is a different, outward-facing action than a direct push
  and so needs its own approval.
