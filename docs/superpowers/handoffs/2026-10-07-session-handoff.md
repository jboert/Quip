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

- eb-branch, 37 commits ahead of `origin/eb-branch`, **not pushed** (owner
  confirms every push).
- CI replay 2026-10-08 (both Apple jobs with CI's exact flags and xcodegen
  2.44.1): Mac 1086 green; iOS failed 14 Keychain-backed tests on the unsigned
  host (-34018), fixed in `daea581` (in-memory backing under XCTest), then
  1132 green. The signed local gate cannot see this class; replay before the
  PR (memory `reference_ci_replay_unsigned_host.md`). `origin/main` has nothing new.
- Gate at the last commit: harness 62, QuipMac 1096, QuipiOS 1134, all green
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
| Mac `/Applications/Quip.app` | eb-branch `4e8aacf`, 1.5.7 Release, Developer ID, installed 2026-10-08 12:22 (fresh pid 50116, port 8765 listening). Menu panel shows `v1.5.7 4e8aacf`. | Nothing. Phone had not reconnected at handoff time (relaunch Quip on the phone); check the Mac Status row for Accessibility / Screen Recording after reconnect, re-grant if red. |
| iPhone (owner's primary) | eb-branch `cea03cb`, 1.5.7, Debug, installed over the air 2026-10-08 11:00. A `4e8aacf` build (pin fix, Q-58) is built at the scratchpad `dd-ios` but the install failed four times with CoreDevice error 4016 (phone `unavailable`); retry `xcrun devicectl device install app` when the phone is unlocked on the LAN. Settings should then show `1.5.7 (4e8aacf, 2026-10-08 12:20)` | Nothing. Force-quit and relaunch after the install. |
| QA simulator D8C5154B | eb-branch `b65c734` (`com.fintechadventures.quip`), paired to the fake Mac on 127.0.0.1:8799, notifications allowed (2026-10-08 14:13). A stray `com.quip.QuipiOS` test host was uninstalled; it had been catching the `quip://` pair link. Must never pair with the real Mac. | Use `tools/fake-mac` (`--ack-paste --error-ids`) for any simulator check; `xcrun simctl push` with `aps.category=waiting.yn` exercises the alert actions. |

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
- **Push** (board Q-55): both peers on `c8aaafb` since 08:56. Team ID now
  defaults to the signing team; the owner enters Key ID `M4XGA5PPAN` once in
  Settings → Notifications and push is back. The phone now shows a red "Push
  on Mac" row until then. DONE 16:00Z by hand (`security add-generic-password
  -T /Applications/Quip.app` for keyId and teamId); push.log shows "push sent"
  at 16:04:18Z.
- SwiftUI review (`/swiftui-pro`) of the branch's views applied in `55f7d86`;
  tray Close is now the pill's long-press; phone rebuilt from it.
- **Q-56 push batching** landed `e93df58`, both peers installed 10:26. Owner
  complained of ~90 pushes/hour; now dwell 10 s, one push per prompt, 8 s
  bundle, Show Prompt Text toggle. Hardware check listed on the board.
- **Q-57 answer from the alert** landed `b4bc759` + `38d46d7` (security review: Reply
  needs an unlocked phone, alert text passes SecretRedactor), both peers installed
  11:00/11:01. Body lists option labels; Reply field; `PushAnswerQueue` keeps a
  lock-screen answer until a socket carries it; delegate installed in
  `didFinishLaunching`. Hardware checks on the board. A watch on
  `~/Library/Logs/Quip/phone.log` for `push_answer sent|unreachable|dropped` was
  running at handoff. `cea03cb` stops the ruflo-rewritten `QuipiOS/ruvector.db`
  from marking builds `-dirty`.
- **Q-57 and Q-58 simulator pass 2026-10-08 14:00–14:16** (board rows have the detail): pinned card first live and after relaunch; lock-screen Yes, Reply and the unreachable alert all verified against the fake Mac with the app killed.
- **Q-58 pin order** landed `1295d31` (phone honours pins over its drag order; a new Mac pin lines up after existing pins). Mac installed; phone install pending (see table).
- **Q-59 Mac SwiftUI review via Ralph PRD** merged `b65c734` (7 stories, all verified by the coordinator, see board). Worktree and branch removed. prd.json/progress.txt re-untracked in `4e8aacf`.
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
