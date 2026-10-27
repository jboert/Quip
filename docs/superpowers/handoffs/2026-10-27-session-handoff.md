# Session handoff — 2026-10-27

Branch: `eb-branch`, pushed through `baee33d`. Session: "phone doesn't connect
after the Mac app is reinstalled / reopened".

## What this session found

The phone connects and authenticates after every Mac relaunch
(`websocket.log` + `kokoro.log`: `auth: PIN matched`, `device_identity`,
heartbeats). The grid was empty because with "Mirror desktop terminals" OFF the
Mac broadcasts only windows whose `isEnabled` is on, and that flag lived in
memory only. "Reset by peer" drops 20–80 s after connect are the phone being
backgrounded; the 1 s drops were Reset taps. Nothing is wrong with the
connection path.

## Commits today (this session)

- `baee33d` fix(mac): enabled window ids persist in UserDefaults
  (`windowEnabledIDs`, keyed to `kern.boottime`); a window comes back enabled
  after a Quip relaunch or reinstall, within one boot. Settings help text
  updated. New `WindowEnabledMemoryTests`; grace test now expects the flag to
  survive a return after the vanish grace.

Earlier today, other sessions (VibeCut sync Q-74..Q-82, board docs):
`018ccc6` `47c5119` `5982933` `38749aa` `e3eccd0` `c757b0d` `82e0fdb`
`2792674` `8173149` `93c24b0` — see `git log --since=2026-10-27`.

## Install state

| Target | Installed | Notes |
|---|---|---|
| Mac `/Applications/Quip.app` | 1.5.7 (`47c5119`), launched 14:26 MST | Predates `baee33d`. Still forgets enables on relaunch until reinstalled. Each Mac install wipes Screen Recording + Accessibility grants, so the owner picks the moment. |
| iPhone | not touched this session | No iOS change in `baee33d`. |

## Verified matrix

| Change | Unit tests | Installed | Hardware-verified |
|---|---|---|---|
| `baee33d` enabled-window memory | QuipMac suite 1236/0 green (gate + pre-commit) | no | no |

## Open threads

1. Install the Mac build (recipe: `reference_quip_install_recipe` memory; ditto
   into /Applications, never `rm -rf`; delete stale build copies after).
   Then verify on hardware: enable a window with Mirror off, quit + reopen
   Quip, phone grid still shows it.
2. "Settings are very confusing" — Phone section of General mixes mirroring,
   any-app dictation and Whisper status. A pass that leads with "what the phone
   shows". Wishlist entry written 2026-10-27.
3. Workaround for the owner right now: Settings → General → Phone → turn on
   "Mirror desktop terminals".

## Shared checkout warning

A Codex desktop session has UNCOMMITTED work in the main checkout (tunnel
detection in `WebSocketServer.swift`, `Shared/ProjectName.swift`, VibeCut
mapper, `PreferencesSyncService.swift`, 12 modified + 3 untracked files). Do not
stage, stash or reset it. `baee33d` was staged by path and by hunk around it.

## Resume

`cd ~/Projects/Quip && git log --oneline -3 && git status --short` then read
this file and pick open thread 1 (ask the owner for the install moment) or 2.
