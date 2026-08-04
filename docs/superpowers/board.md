# Quip board

Working branch: `eb-branch` (long-lived; see the branch policy note at the bottom).
Source of truth for context on each item: `docs/superpowers/wishlist.md`.

Lives here, not in `tasks/` — that directory is gitignored (ralph-loop artifacts),
so a board written there is invisible to the next session and to anyone else.

Status: `ready` (picked up in priority order) · `in progress` · `blocked` · `done`.

## In progress

_(none)_

## Ready

_(none)_

## Blocked

| ID | Title | Blocked on |
|----|-------|-----------|
| Q-A1 | Acceptance: phone→Mac leg of multi-select | A paired phone. The Mac requires a PIN, so the WebSocket hop cannot be driven from a script here. Everything downstream of it is verified by direct injection. |
| Q-A2 | Install the current iOS build on the phone | `devicectl` reports the iPhone `unavailable` (it pairs over Bonjour, so it needs USB or the same Wi-Fi, unlocked). The phone is running the build from earlier today: it HAS the `[✔]` + Submit-row detector, it does NOT have the divider rule (`ec9308b`), so it still shows "Chat about this" as a chip. Mac side is current. |

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
| Q-6b | The widget's free-text row ("Type something") is no longer offered as a chip — rule read out of the shipped CLI binary, not guessed at | this commit |

## Branch policy

Work stays on `eb-branch`. Merging to `main` and pushing to GitHub are **not**
automatic here: the repo owner has a standing rule that pushes need explicit
per-push confirmation, and there is an open PR (#29) that makes main-conflicting
operations unsafe to take unilaterally. Finished work is committed on
`eb-branch` and reported; the merge-back is the owner's call.
