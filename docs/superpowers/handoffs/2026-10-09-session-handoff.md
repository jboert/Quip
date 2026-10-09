# Session handoff — 2026-10-09 (follows 2026-10-07-session-handoff.md)

Written at ~50% context. Owner intends to push eb-branch to origin today.

## Resume in one line

`git log --oneline origin/eb-branch..eb-branch` on eb-branch (68 ahead at `7761b50`), read `docs/RELEASE_NOTES.md` (top section) and board rows Q-57 to Q-63; nothing is in flight, the next owner calls are "push", a real-alert check, and the phone pin check.

## Branch state

- eb-branch `7761b50`, clean, 68 commits ahead of `origin/eb-branch` (`e5ed6ee`), **not pushed**.
- Gate at the last code commit (`bbddd32`): harness 15 checks, QuipMac 1155, QuipiOS 1167, all green
  (`QUIP_QA_SIM_UDID=D8C5154B-7030-40BA-8443-F4F9EB27C725 tools/check.sh`).
- Release notes for the push: `docs/RELEASE_NOTES.md`, section "eb-branch → 2026-10-09" (`117525c`).
- Untracked junk from the ruflo plugin, left alone: `ruvector.db`, `agentdb.rvf`, `agentdb.rvf.lock`.

## Commits today (newest first)

| Hash | Why |
| --- | --- |
| (see `git log`) | Q-64 broadcast tile beside the mic, bar off by default; release notes and board updated; phone reinstalled clean. |
| `7761b50` | Handoff: phone on `9031192`, clean stamp. |
| `9031192` | Board/handoff: pin investigation, release notes written, why a stamp reads `-dirty`. |
| `117525c` | Release notes "eb-branch → 2026-10-09", everything since `e5ed6ee`. |
| `bbddd32` | Pinning from the card menu clears the card's free-drag position and forces an arranged mode; fake Mac handles `set_pin`. |
| `6ed46ae` | Board/handoff: edge-clipping regression fixed and installed. |
| `93a323b` | Main row no longer wider than the screen (the 44 pt chevron frames from `af0c65c` clipped every row); ⋯ hides on cards under 120 pt. |
| `25c6bd9` | Board/handoff: Q-63 landed, both peers installed. |
| `47968a3` | Q-63: a backup never overwrites a newer phone edit (`PreferencesSnapshot.savedAt`, `PreferencesFreshness`); PIN field after a rejected saved PIN; compact broadcast bar; Q-61 hint removed; fake Mac stores/serves backups with `freeze`/`thaw`. |
| `fb04ca1` | Audit text saved, board Q-62, one Quip on the phone again. |
| `af0c65c` | Q-62 design-audit fixes: card titles in text colour, secondary line full alpha, 44 pt chevrons (regressed, see `93a323b`), mic as the one tinted tile, "Loading windows…" before the first layout. |
| `d633536` | Board/handoff: Q-61 landed and installed. |
| `383c7db` | Q-61: ⋯ button on every card, Color as named swatches in the menu, one-time hint (removed later); fake Mac handles `set_color`. |
| `27d39b4` | Board/handoff: Q-60 installed; simulator cannot prove the extension. |
| `0a67664` | Q-60: alerts name who is asking (subtitle), show the question (prompt text on by default), generic waits passive; `QuipNotificationService` extension retitles buttons from `quip_option_labels`. |
| `0215567`, `7dbef66`, `a0fb3d9`, `469a32b` | Board: Q-57/Q-58 simulator checks, Q-59 PRD landed, install state. |

Earlier today's-session commits (`4e8aacf` back to `ba3593e`) are in the previous handoff and the release notes.

## Install state

| Peer | Installed | Missing |
| --- | --- | --- |
| Mac `/Applications/Quip.app` | eb-branch `47968a3` code, 1.5.7 Release, Developer ID, installed 2026-10-09 09:39 (pid 63701, port 8765 listening). Stamp reads `47968a3-dirty` (docs uncommitted at build time; same code). No Mac code changed after `47968a3`. | Nothing. A clean rebuild would only fix the stamp text and may cost a TCC re-grant; owner's call. |
| iPhone (owner's primary) | eb-branch `9031192`, 1.5.7 Debug, stamp `9031192 2026-10-09 10:09` (clean), installed over the LAN 10:11. Stray `com.quip.QuipiOS` 1.5.6 uninstalled 2026-10-09; one Quip icon. | Nothing. Force-quit and relaunch after any install. |
| QA simulator D8C5154B | Working-tree build (the gate installs its test host), paired to the fake Mac on 127.0.0.1:8799; notifications allowed. | Fake Mac binary and FIFO under `$TMPDIR/quip-work/` (rebuilt from `tools/fake-mac/fake-mac.swift` as needed). |

## Hardware-verified vs install-only

| Work | Unit tests | Simulator (fake Mac) | Hardware |
| --- | --- | --- | --- |
| Q-56 push batching | green | n/a | push.log shows bundled sends (2026-10-08 17:28Z) |
| Q-57 answer from the alert | green | Yes / Reply / unreachable / flush, app killed | **not seen**: no `push_answer` line in phone.log yet |
| Q-60 descriptive alerts + labelled buttons | green | body/subtitle via `simctl push`; extension cannot run there | **not seen**: a real APNs alert with `mutable-content` |
| Q-58 pin order | green | Mac-side pin and phone-side `set_pin` both put the card first | owner reports it still fails; retest on `9031192` |
| Q-61 card menu / colours | green | ⋯ → Color → swatch recolours (`set_color`) | not confirmed |
| Q-62 audit fixes + clipping fix | green | measured: status row x 6–430 of 440, chevrons 8/38 | owner's screenshot showed the clipping; fix installed after |
| Q-63 settings guard | green (`PreferencesFreshnessTests`) | stale backup: old build reverted, new build kept the edit | not confirmed |
| PIN field after rejection | n/a | field appears, 8 digits fit, auth OK | not confirmed |
| Q-59 Mac SwiftUI PRD (US-001..007) | green | n/a | Save Layout / Apply, Arrange message, VoiceOver, Reduce Motion unseen |

## Open threads

- **Push** on the owner's word only (standing rule). Branch is ready: clean, gated, release notes written.
- **Pin from the phone** (Q-58): simulator path works; `bbddd32` hardens the phone side. If it still fails on the real Mac, check `isPinned` in the layout the Mac broadcasts after `set_pin` (`QuipMacApp.swift` `case "set_pin"` → `windowManager.togglePin` → `broadcastLayout`).
- **Labelled alert buttons** (Q-60): only a real push proves the extension. Phone's Test Push (Settings → Notifications) sends a labelled 3-option alert. If buttons still read 1/2/3: `log stream --predicate 'process == "QuipNotificationService"'` over USB.
- **Push volume**: 217 pushes 2026-10-08 20:24 → 2026-10-09 09:00 (peak 93/h, 181 single-window). Not analysed; owner has not complained since Q-56.
- **PIN length**: 8 digits by design (GH #14); owner can type a shorter one into Mac Settings → Security; QR / Send to iPhone skips typing.
- **"Too zoomed in"**: was the clipping regression, fixed `93a323b`. Terminal text size is the phone's own pref (`terminalTextSize`, default 13).
- Owner calls still open: Q-52 VibeCut sync answers, Q-54 dictation model, Q-50/Q-51 approvals, "restore buttons".
- Simulator traps learned today are in memory `reference_simulator_qa_with_fake_mac.md` (gate replaces the sim app; `defaults write` by bundle id misses the container; notification switch flips only by drag; `simctl push` skips service extensions).
