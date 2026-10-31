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

## Q-90 Ralph run (night)

PRD (7 stories) ran in `../Quip-ralph-q90` on `ralph/q90-mac-stays-up`, 8 of 10 iterations, all passing. Verified by reading the diff; 7 watchdog mutants and 6 Swift mutants all killed; `tools/qa/q90-down.sh` and `q90-restart.sh` PASS on D8C5154B with screenshots checked. Gate `--all` green on the branch and on eb-branch after the merge (QuipMac 1345, QuipiOS 1563, harness 62, fake-mac 48, watchdog 71; QuipLinux / QuipAndroid skipped, not built here). Merged `df5ff35`, scaffolding untracked `dc7bdd5`, pushed; branch and worktree removed.

Installed on the iPhone at `b70769f`. Open: the Mac wiring (owner present), and the watchdog's "any new pid is a crash" rule (see wishlist).

## Q-90 Mac wiring (2026-10-31)

`474cf00` + `f9ee248` installed via `tools/install-mac.sh` (Mac at `f9ee248`). launchd owns Quip now: a bare kill comes back. Checks 1–3 of spec §8 pass on the Mac (spec §9). Open: phone checks, permissions check, Stop Quip… and crash-loop checks, US-006 Turn on, US-007.

## iPhone Debug launch crash (2026-10-31)

`d51b9b6` Debug on the iPhone crashed at launch (two .ips, 20:40 / 20:41 local): stack guard hit under `MainiOSView.windowLayout`, main thread, 1008 KB stack. Measured in the simulator with a temporary probe: 1078 KB used at windowLayout (body 137 KB, rootLayers 746 KB). Fixed `b1df59f` with AnyView at each body stage and around rootLayers' big children: peak 251 KB. `StackHeadroom` (DEBUG) asserts above 512 KB; a 100 KB budget fired at 237 KB, so the guard works. iPhone runs the fixed Debug build (05:12Z install, launched, PTT). If a phone Debug install ever dies at launch again with "stack guard", look here first.

## Q-90 restart frames (2026-10-31)

`85e3e8b`: each restart row in Mac Settings → Reliability lists the top three Quip frames (crash: `.ips` faulting thread; hang: watchdog sample), and so do Copy for a ticket and the crash-loop notice. Mac installed at `85e3e8b` via `tools/install-mac.sh` (Developer ID, launchd pid). Owner to glance: the 03:06 hang row should show `main`; the two `kill -9` rows have no frames (no report). Still open in Q-90: the phone's "keeps crashing" / "disk full" wording (no channel while Quip is down), and the owner checks in the wishlist.

## Q-90 crash-loop check on hardware (2026-10-31, 06:01Z)

Three `kill -9` at 06:01:17 / 06:01:31 / 06:02:02Z: launchd relaunched after the first two; the watchdog logged `crash_loop restarts=3 window=10m action=stopped retry_at=1793428350` at 06:02:30Z, booted the agent out (`launchctl print` 113), wrote `stoppedForCrashLoop`; no Quip running. Phone logged `mac_down kind=quip_down` between kills. Manual `open` at ~06:04Z: handed off to launchd, marker cleared, one-time notice shown ("Quip was stopped after crashing 3 times in 10 minutes"; no frames, as kill -9 leaves no report). Not verified: the 30-min automatic retry (Quip was reopened by hand first; covered by run-watchdog-tests.sh), and the phone screen during the stop.
