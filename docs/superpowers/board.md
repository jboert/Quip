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
| Q-19 | §58 Iteration 4 — drag-to-resize promise | The toggle advertises a resize gesture that does not exist. Two options: implement handles backed by `customFrames`, or hide the toggle. **Needs an owner decision before it can be worked.** |

## Blocked

| ID | Title | Blocked on |
|----|-------|-----------|
| Q-18a | §58 Iteration 1 manual smoke | Reorder in the layout preview and confirm the sidebar + Arrange agree; then a multi-display pass: select the secondary display, Arrange, confirm windows stay on it. Needs a Mac install. |
| Q-17a | §58 Iteration 2 manual smoke | Create / edit / delete a prompt from the phone, save while disconnected, and try a duplicate sanitized id. Needs a Mac + iOS install (two-peer). |
| Q-16 | §58 Iteration 3 manual smoke | Close tracked iTerm windows during active polling and confirm no stale state or source churn. Needs the new Mac build installed (`0a1b206` is committed but `/Applications/Quip.app` predates it). |

## Done

| ID | Title | Landed |
|----|-------|--------|
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
| Q-17 | §58 Iteration 2 — prompt mutation trust. Acks/pending UI/metadata had landed earlier; the last gap was client-side id validation, now a shared sanitizer with a filename preview and a collision warning | `PENDING` |
| Q-19a | §58 Iteration 4 — spawn-path quoting, accessibility labels, protocol docs | `PENDING` |
| Q-18 | §58 Iteration 1 — one order source for sidebar/preview/arrange, Arrange targets the selected display in AX coordinates, failures surface instead of doing nothing, row numbers mean arrange slots | `PENDING` |
| Q-13 | CI had failed at step one on every run since `f19760d`: an unanchored `scripts/` in `.gitignore` matches at ANY depth, so `.github/scripts/` was never committed and the workflow called two files that do not exist on a runner | `889db83` |
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
