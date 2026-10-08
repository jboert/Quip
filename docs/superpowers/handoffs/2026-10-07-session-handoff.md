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

- eb-branch, 14 commits ahead of `origin/eb-branch`, **not pushed** (owner
  confirms every push). `origin/main` has nothing new.
- Gate at the last commit: harness 62, QuipMac 1079, QuipiOS 1128, all green
  (`QUIP_QA_SIM_UDID=D8C5154B-7030-40BA-8443-F4F9EB27C725 tools/check.sh`).
- Untracked junk from the ruflo plugin, left alone: `ruvector.db`,
  `agentdb.rvf`, `agentdb.rvf.lock`, `QuipiOS/ruvector.db`.

## Commits this session (newest first)

| Hash | Why |
| --- | --- |
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
| Mac `/Applications/Quip.app` | 1.5.6, built Sep 22 03:39 | Every Mac commit since Sep 22: the whole QA-fix Mac batch (US-008 to US-011, US-014 Mac half, APNs test backing), US-115/116, Q-53. The owner must be off the phone for the install (TCC re-grant drops the link); recipe in `reference_quip_install_recipe.md`. |
| iPhone (owner's primary) | Unknown build; owner was voice-testing and said to wait for "install" | US-101 to US-114, Q-53 phone half, the QA-fix phone batch. |
| QA simulator D8C5154B | Nothing installed; must never pair with the real Mac | Use `tools/fake-mac` (`--ack-paste --error-ids`) for any simulator check. |

One phone socket was ESTABLISHED on port 8765 at handoff time.

## Hardware-verified vs install-only

| Work | Unit tests | Simulator | Hardware |
| --- | --- | --- | --- |
| Broadcast phone half (US-106–114) | green | not done (screenshots of shelf, typed suggestions, both bar layouts owed) | not installed |
| Broadcast Mac half (US-115/116) | green, incl. `osacompile` of the Terminal guard | n/a | not installed; four checks listed under Q-49 |
| Minimize (Q-53) | green | possible now with fake Mac, not done | not installed; check listed under Q-53 |
| QA-fix batch (addendum 3) | green | partly | not installed |

Nothing from today has run on hardware.

## Open threads

- **Q-52 VibeCut sync (owner call).** Plan Orchestrator IS synced and current.
  Real gaps: the `mode=send` filter drops Proceed; Prompt Lab versions and
  editor overlays (`Application Support/VibeCut/actions/*.scpt`) never reach the
  catalog file; the QA simulator's fake Mac serves 12 invented prompts. Owner
  must say which surface showed the gap and whether Proceed should inherit.
  Memory: `project_vibecut_sync_gaps.md`.
- **Push still dark** until the Mac install lands `118c58d` and the owner
  re-enters Team ID + .p8 (board Q-48).
- **Quick-button backup restore** still owed on the owner's "restore buttons"
  (recipe in addendum 3).
- **Q-50 key styles, Q-51 long-press discoverability**: PRDs/spec pending owner
  approval; not started.
- **Security review note** on `BroadcastLink.swift` (deep link to text in a
  terminal): by design, the link only fills the sheet; nothing sends without
  a Send tap. No action.
- **Minor**: every single-window paste now gets an ack the phone's latency
  tracker never registered, so one `send_text_ack with unknown messageId`
  NSLog per paste. Harmless; quiet it if it annoys.

## Owner calls open

"install" (phone), Mac install when off the phone, "push", "restore buttons",
APNs re-entry after the Mac install, Q-52 answers, Q-50/Q-51 approvals.
