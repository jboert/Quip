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

## Install state (updated 19:11 MST)

| Target | Installed | Notes |
|---|---|---|
| Mac `/Applications/Quip.app` | built from `75838b5` (eb-branch HEAD, includes `baee33d` + the Codex session's Q-83/Q-84), launched 19:09 MST, pid 23282 | Developer ID signed, verified. Built from a clean worktree, not the dirty checkout. `nm` shows `systemBootTime`/`prunedEnabledWindowIDs`. TCC re-grant may be needed. |
| iPhone 17 Pro Max | same `75838b5`, Debug, installed OTA via devicectl (`00008150-000248600280401C`) at 19:11 MST | First attempt reset mid-transfer (NWError 54), second succeeded. Force-quit from the app switcher before judging anything. |

## Verified matrix

| Change | Unit tests | Installed | Hardware-verified |
|---|---|---|---|
| `baee33d` enabled-window memory | QuipMac suite 1236/0 green (gate + pre-commit) | yes (Mac) | no — owner: enable a window with Mirror off, quit + reopen Quip, grid keeps it |
| `75838b5` Q-83/Q-84 (Codex session) | its own gate | yes (Mac + iPhone) | no |

## Open threads

1. Hardware-verify `baee33d`: enable a window with Mirror off, quit + reopen
   Quip, phone grid still shows it. (Installed 19:09 MST.)
2. "Settings are very confusing" — Phone section of General mixes mirroring,
   any-app dictation and Whisper status. A pass that leads with "what the phone
   shows". Wishlist entry written 2026-10-27.
3. Workaround for the owner right now: Settings → General → Phone → turn on
   "Mirror desktop terminals".

## Shared checkout warning

A Codex desktop session was editing the main checkout alongside this one; it
committed its work as `75838b5` (Q-83/Q-84) at ~19:05 MST. Tree clean after
that. `baee33d` had been staged by path and by hunk around its edits. Check
`git status` before touching anything: that session may still be active.

## Resume

`cd ~/Projects/Quip && git log --oneline -3 && git status --short` then read
this file and pick open thread 1 (ask the owner for the install moment) or 2.
