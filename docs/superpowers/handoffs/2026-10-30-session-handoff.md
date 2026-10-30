# Session handoff — 2026-10-30

To resume in a fresh session, say: "Read docs/superpowers/handoffs/2026-10-30-session-handoff.md, then pick up Q-88 after US-011 (US-012 is in the Berriscope repo)."

## Where things are

Branch `eb-branch`, pushed, clean (only untracked `agentdb.rvf*` / `ruvector.db`, not ours). Spec: `docs/superpowers/specs/2026-10-29-pick-up-where-i-left-off.md` — US-000 … US-011 ticked, with *As built* notes where the build differs from the text.

Installed: iPhone at `9b07c1d` (Release, devicectl). Mac app at `1505be7` (Q-89); not rebuilt since — every change after it is phone-only. The Mac decodes the prefs snapshot into the struct, so it drops `windowOrderMode` until its next rebuild (iCloud carries it meanwhile).

## Shipped this session (newest first)

| Commit | What |
|---|---|
| `9b07c1d` | US-011: long-press a window → "Remote in here" (select, wait ≤ 500 ms for the Mac's echo, open the link); Backends row → "Remote in". No host opens the setting; no app → toast with Settings. Berriscope preset shown only where Berriscope is installed (owner-only app). |
| `cd25dcc` | Fix: launch crash when the mic input has no format (0 Hz) — every `installTap` now checks `SpeechService.canTapInput`. Seen on the QA sim after a boot. |
| `101cdc0` | US-010: Settings → Connection → Remote in (presets with cited schemes, Custom link, host defaults to Tailscale name, live preview). `PreferencesSnapshot.remoteInJSON` (Shared). |
| `1f729cd` | US-009: after ≥ 2 min away, jump to a waiting window that ASKS something (owner chose "question on screen"); probes up to 4 screens, 1.2 s, Back toast; setting in Notifications. |
| `8b8e0e1` | US-008: terminal text opens where it was left scrolled (relaunch + switching back). Anchor = SHA-256 prefix of the line + distance from end, never the text. Text mode only. |
| `cbf5d1c` | US-004 fix: the Recent order is taken on launch / return / Mac switch / turning Recent on, never while tapping (the tapped card used to slide away under the next tap). `q88-s4.sh` updated. |
| `8a51cfb` | ActionToast: VoiceOver reads "Order: Manual, Use Recent" (`.combine` had dropped the button). |
| `91cd265` | Q-89 fix: Yes / No bar only when a question is on screen (idle agents are "waiting" too). |
| `b4e7da7` | US-007: unsent text per window (`DraftBook`, protected file in Application Support, 4 KB / 50 per Mac). |
| `6652161` | US-006: relaunch within 30 min restores window, chips, panels (`PlaceRestorePolicy`, `land(...)`); `tools/qa/q88-s6.sh`. |
| `7b8d90c` | US-005: `PhonePlace` saved on background, per Mac, device-local. |
| `3482bc9` | US-004: Recent / Manual grid order, `ActionToast`. |

Another session (Claude-Session …MDytKdm) landed `d3090c3` (only tracked prefs count as edits; `q88-s4.sh`) and `3019d20` (the first-layout order guess is phone-only, `windowOrderModeGuess`).

## Next

1. Owner hardware check for Remote in (spec §7 item 5 needs Berriscope US-012, which lives in the Berriscope repo and is owner-only).
2. Mac rebuild some time (carries `windowOrderMode` and `remoteInJSON` in the backup); costs TCC re-grants.

## Open risks / not verified

- Backend switch restore (US-006) and per-Mac drafts (US-007) are unit-tested only: the fake Mac is one backend.
- Draft file protection is checked on device only (simulator has no data protection).
- Q-89 arrow walk not yet seen in a live Claude/Codex menu on hardware.
- Screenshot terminal view does not restore scroll (US-008 is text mode).

## QA simulator notes

- D8C5154B: a stray sim-level plist (`data/Library/Preferences/com.fintechadventures.quip.plist`, from a bundle-id `defaults write`) fed old values to every "fresh install" run; deleted. Never write by bundle id (memory updated).
- Scripts: `tools/qa/q88-s2.sh`, `q88-s3.sh`, `q88-s4.sh`, `q88-s6.sh`. S4/S6 pass at `8b8e0e1`'s parent; S5/S7/S8 were run by hand.
- `pkill -f "fake-mac --port 8799"` stops a fake (a `./fake-mac` command line does not match a path pattern).
