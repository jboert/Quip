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

## Later the same evening

- Quick buttons verified on hardware after the reinstall: three taps at
  19:20:52, 19:20:58, 19:21:07 MST, all `send_text … success=1 press_return=1`
  into iTerm2 (`latency.log`). Mac Accessibility survived the reinstall.
- `f3ef01a` feat(build): Settings version row now "1.5.7 (1641, f3ef01a, …)":
  the commit count rides in `QuipBuildNumber`; CFBundleVersion untouched
  (watch + extensions must match it). Installed OTA on the iPhone at 19:42
  MST (build 1641). Mac NOT reinstalled for it (each Mac install risks the
  TCC grants; the Mac still shows "1.5.7 (75838b5, …)").
- Owner reported "on mobile it says UNKNOWN". Not located: the version row
  cannot say that in these builds; the only "Unknown" captions are the
  backend-list row (enabled, no session yet) and a URL without a host in the
  diagnostics sheet. Ask which row.
- **Gate is red at HEAD, not from this session:** `PromptLibraryVibeCutTests`
  fails 9/16 at a clean worktree of `73d56ab` (also `75838b5`): the real
  `~/Projects/vibecut` "Update email draft" prompt leaks into fixture-based
  tests since the Q-83 project-prompts change. Codex session's lane. `f3ef01a`
  was committed with `QUIP_SKIP_CHECK=1` for that reason only; its own tests
  ran green (harness, QuipiOS 1320/0, BuildInfoTests 6/0).

## Open threads

1. Hardware-verify `baee33d`: enable a window with Mirror off, quit + reopen
   Quip, phone grid still shows it. (Installed 19:09 MST.)
2. "Settings are very confusing" — Phone section of General mixes mirroring,
   any-app dictation and Whisper status. A pass that leads with "what the phone
   shows". Wishlist entry written 2026-10-27.
3. Workaround for the owner right now: Settings → General → Phone → turn on
   "Mirror desktop terminals".

## Q-85 / Q-86 shipped (23:55 MST)

Spec: `docs/superpowers/specs/2026-10-27-q85-q86-phone-knows-vibecut-and-mac-build-design.md`.
Rebased onto the Codex session's `46ecfe4` (no file overlap), gate green on
the combined tree, pushed.

- `d67fb77` feat(sync): Prompts hub shows the Mac's VibeCut freshness (Q-85).
- `c3592d9` feat(phone): Settings names the Mac build (Q-86).
- `d8d293d` fix(phone): the whole Mac build row copies (sim pass caught a
  dead gap in a plain-style button).

Verified on the QA simulator against the fake Mac: orange "VibeCut changed
since the last sync — Sync" at the top of the hub, tap → "12 synced" flash
and "Up to date with VibeCut · 12 prompts · just now", `vibecut changed` on
the fake's console → orange again on reopen; Settings → "Mac build ·
0.0.0 (0) fake000", tap → "Copied". Mutation checks from the spec all fail
their test.

Phone: `d8d293d` (build 1652) installed OTA on the iPhone. Force-quit and
relaunch to pick it up. Until the Mac is reinstalled, the phone shows
neither line (the running Mac predates both messages; by design, not a bug).

Mac: NOT installed. `/Applications/Quip.app` still predates `75838b5`. The
next Mac install (owner picks the moment; it risks the TCC grants) brings
Q-83..Q-86 at once. Hardware acceptance for both lives in the spec's
Acceptance sections.

## 2026-10-28 morning: acceptance, fan-out, fixes, Mac install

- Agent-run hardware acceptance A1–A6: all pass (results in the
  hardware-acceptance spec). A1 found a stale sync ack, fixed `1fcb85b`.
- Fan-out (5 tracks) found and fixed: `22f83e6` the Q-85 probe timeout
  really bounds the wait + replies send the probe's answer + no MainActor
  stat; `87d6a6f` tunnel refusal compares the sanitized, case-folded id;
  `7756f32` the Mac Settings editor keeps a prompt's tags on save.
- Owner no longer uses the Cloudflare tunnel (memory
  `project_no_cloudflare_tunnel`); O3 step 2 is not applicable.
- **Mac installed `7756f32` (build 1660) at 08:00 MST**, grants intact,
  enabled windows unchanged. Phone still `d8d293d` (1652): fine, the
  phone-side code for Q-85/Q-86 is in it.
- Next: owner's phone sitting O1, O2, O3 (Tailscale steps), O4, O5, with the
  log tail running to `<scratch>/button-test.log`. Then the "settings are
  very confusing" pass.

## Shared checkout warning

A Codex desktop session was editing the main checkout alongside this one; it
committed its work as `75838b5` (Q-83/Q-84) at ~19:05 MST. Tree clean after
that. `baee33d` had been staged by path and by hunk around its edits. Check
`git status` before touching anything: that session may still be active.

## Resume

`cd ~/Projects/Quip && git log --oneline -3 && git status --short` then read
this file and pick open thread 1 (ask the owner for the install moment) or 2.
