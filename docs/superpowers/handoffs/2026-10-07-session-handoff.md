# Session handoff — 2026-10-07, late evening (follows addendum 3)

Written at ~50% context. The earlier part of the day is in
`2026-10-07-session-handoff-addendum-3.md` (QA-fix batch, the settings-overwrite
incident, push being dark). This file covers what landed after it.

## Resume in one line

`git log --oneline origin/eb-branch..eb-branch` on eb-branch, then read board
Q-49, Q-52 and Q-53 in `docs/superpowers/board.md`; nothing is installed yet,
so the next real step is the owner's "install" (phone) and a Mac install when
the owner is off the phone.

## Branch state

- eb-branch, 24 commits ahead of `origin/eb-branch`, **not pushed** (owner
  confirms every push). `origin/main` has nothing new.
- Gate at the last commit: harness 62, QuipMac 1086, QuipiOS 1132, all green
  (`QUIP_QA_SIM_UDID=D8C5154B-7030-40BA-8443-F4F9EB27C725 tools/check.sh`).
- Untracked junk from the ruflo plugin, left alone: `ruvector.db`,
  `agentdb.rvf`, `agentdb.rvf.lock`, `QuipiOS/ruvector.db`.

## Commits this session (newest first)

| Hash | Why |
| --- | --- |
| `90617b8` | Protocol doc: the iTerm2 Cmd+V route (Codex/Grok, multi-line) is not quiet and cannot be; fake Mac answers unknown prompt ids with the Mac's attributed error under `--ack-paste`; board review notes. |
| `07237db` | Phone review fixes: Broadcast… from the main-screen hub never opened (dismiss before post); the 4 s hide cut Retry's 15 s short; a refused target read "did not answer"; paste acks logged "unknown messageId"; `QUIP://` never routed; sheet decoded the usage store twice per keystroke. |
| `c159a85` | Mac review fixes: `{{clipboard}}` in a broadcast read an earlier target's pasted body (now the burst snapshot via `KeystrokeInjector.userClipboardString`); quiet Terminal.app requests with a window id skip the Accessibility raise (the script raises on the serial queue); minimize toast names the real cause. |
| `14a870d` | Board and handoff: simulator pass results, Q-54 dictation model question. |
| `dd78283` | Select All in the Broadcast sheet never took (two Buttons in one Form row). |
| `b1bbf9e` | This handoff. |
| `d1e8d4a` | Board: Q-53 built, hardware check owed. |
| `8e767f3` | Q-53 / GH #39: minimize a window from the phone (`minimize_window`, `WindowState.isMinimized`, `WindowManager.minimizeWindow` through the AX match that `focusWindow` now shares as `resolvedAXWindow`), a tray above the grid while anything is minimized, Minimize/Restore in the card menu, fake Mac support. |
| `e5b493b` | Board: Q-53 filed from the owner's dictated idea, with GH #39. |
| `a4b1218` | Board: Q-49 landed on both halves, hardware checks listed. |
| `cc9ac83` | US-115 + US-116: `paste_prompt` acks, `error.messageId` so a broadcast target fails at once, `raiseWindow` so a broadcast does not flash every iTerm2 window, Terminal.app scripts raise and verify their own window by id inside the serial AppleScript queue. Phone settles a sent target on a late ack or an attributed error. Protocol doc gains `send_text_ack` and `paste_prompt`. |
| `42fa25c` | Board: Q-52, the VibeCut sync trace (see Open threads). |
| `a88e554` | US-106 to US-114 (iOS only): Broadcast suggestions and Most used shelf, library prompts filled per window through `paste_prompt`, Broadcast from a prompt row, Broadcast as a Quick Button with a hideable bar, Press Return toggle, delivered-N-of-N line with retry, usage ranking, disabled reason, `quip://broadcast`. This was the uncommitted work the session started on. |

Everything from `5ffd8f2` back is addendum 3's.

## Install state

| Peer | Installed | Code it is missing |
| --- | --- | --- |
| Mac `/Applications/Quip.app` | eb-branch `c825a59`, 1.5.7 Release, Developer ID, installed 2026-10-08 08:28 (fresh pid 37401, port 8765 listening). Menu panel shows `v1.5.7 c825a59`. | Nothing. Phone had not reconnected at handoff time (relaunch Quip on the phone); check the Mac Status row for Accessibility / Screen Recording after reconnect, re-grant if red. |
| iPhone (owner's primary) | eb-branch `c825a59`, 1.5.7, Debug, installed over the air 2026-10-08 08:28 (devicectl, localNetwork transport). Settings shows `1.5.7 (c825a59, 2026-10-08 08:28)` | Nothing. Force-quit and relaunch after the install. |
| QA simulator D8C5154B | Nothing installed; must never pair with the real Mac | Use `tools/fake-mac` (`--ack-paste --error-ids`) for any simulator check. |

One phone socket was ESTABLISHED on port 8765 at handoff time.

## Hardware-verified vs install-only

| Work | Unit tests | Simulator | Hardware |
| --- | --- | --- | --- |
| Broadcast phone half (US-106–114) | green | not done (screenshots of shelf, typed suggestions, both bar layouts owed) | not installed |
| Broadcast Mac half (US-115/116) | green, incl. `osacompile` of the Terminal guard | n/a | not installed; four checks listed under Q-49 |
| Minimize (Q-53) | green | possible now with fake Mac, not done | not installed; check listed under Q-53 |
| QA-fix batch (addendum 3) | green | partly | not installed |

Both peers now carry today's code (installed 2026-10-08 08:28); the hardware checks listed under Q-49 and Q-53 are runnable.

## Open threads

- **Q-52 VibeCut sync (owner call).** Plan Orchestrator IS synced and current.
  Real gaps: the `mode=send` filter drops Proceed; Prompt Lab versions and
  editor overlays (`Application Support/VibeCut/actions/*.scpt`) never reach the
  catalog file; the QA simulator's fake Mac serves 12 invented prompts. Owner
  must say which surface showed the gap and whether Proceed should inherit.
  Memory: `project_vibecut_sync_gaps.md`.
- **Push**: the Mac install (`c825a59`, includes `118c58d`) landed 2026-10-08;
  the owner re-enters Team ID + .p8 in Settings once, then push is back (board Q-48).
- **Quick-button backup restore** still owed on the owner's "restore buttons"
  (recipe in addendum 3).
- **Q-50 key styles, Q-51 long-press discoverability**: PRDs/spec pending owner
  approval; not started.
- **Security review note** on `BroadcastLink.swift` (deep link to text in a
  terminal): by design, the link only fills the sheet; nothing sends without
  a Send tap. No action.
- **Review pass 2026-10-08** (local code-review, high effort, 13 findings):
  10 fixed in `c159a85` / `07237db` / `90617b8`. Left by design: `isMinimized`
  infers a restore from the snapshot (board Q-53 note); the iTerm2 Cmd+V route
  still activates iTerm2 per target (docs/protocol.md). `/code-review ultra`
  refused the branch as too large (240 files); run it against a closer base
  if wanted.

## Owner calls open

"install" (phone), Mac install when off the phone, "push", "restore buttons",
APNs re-entry after the Mac install, Q-52 answers, Q-50/Q-51 approvals.
