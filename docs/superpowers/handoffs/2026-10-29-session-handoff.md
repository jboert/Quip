# Session handoff — 2026-10-29

## Commits today (eb-branch, all pushed)

| Hash | Why |
|---|---|
| `99927a4` | fix(mac): a full disk no longer aborts Quip from a log append (SIGABRT in `appendPhoneLog`) |
| `8b478d9` | docs(board): Q-88 opened — pick up where I left off, plus one-tap Remote in |
| `63b5e0a` | docs(board): Q-88 remote presets stay generic; Berriscope needs a link handler |
| `dd27444` | docs(board): Q-88 Recent is the default grid order (owner yes) |
| `8aad0fa` | docs(board): Q-88 30-minute restore window agreed |
| `8de6b44` | docs(spec): Q-88 spec moved to `docs/superpowers/specs/2026-10-29-pick-up-where-i-left-off.md`, ready to build |
| `52b52fe` | fix(mac): Grant on the Automation (iTerm) row now asks macOS (`AEDeterminePermissionToAutomateTarget`, `askUserIfNeeded: true`) instead of only opening System Settings |

## Incident: Quip lost Automation access to iTerm (open)

- iTerm (`~/Applications/iTerm.app`, 3.7.6) updated and relaunched 17:30:33 local; from 17:33:47 every Apple Event to iTerm returns `-1743` (`errAEEventNotPermitted`) — Quip **and** a plain `osascript` from a shell. System Events / Finder still fine. System Settings still showed Quip → iTerm.app on.
- Effect: `SESSION_FETCH failed` in `~/Library/Logs/Quip/injection.log` (streak 1380+), session map frozen, Settings row red.
- Done: `tccutil reset AppleEvents com.quip.mac` (also clears Quip's Terminal.app + System Events grants — re-prompt on first use); built + installed `52b52fe`.
- **Still failing at handoff time** (01:43:46Z streak=1 after relaunch). Owner has not yet clicked the new Grant button.
- Next: owner clicks Grant on Settings → General → Automation (iTerm) → OK in the macOS dialog. Verify with `tail -f ~/Library/Logs/Quip/injection.log` for `SESSION_FETCH recovered`. If Grant opens System Settings instead (stored denial), toggle iTerm there. Owner runs this session inside iTerm, so quitting iTerm is not an option.
- Gate note: `ITermVerbSmokeTests` (13 tests) fail while iTerm denies Apple Events; they drive the live iTerm. `52b52fe` committed with `QUIP_SKIP_CHECK=1` for that reason only.

## Install state

- Mac: `/Applications/Quip.app` = `52b52fe`, Release, Developer ID D2PM6R797Q, launched 18:43:43 local. Build copies unregistered/removed (DerivedData Debug copy kept for tests, unregistered from LaunchServices). Accessibility / Screen Recording may need re-grant after this reinstall — not yet checked.
- iOS: no install today.

## Verified on hardware vs install-only

| Item | State |
|---|---|
| `99927a4` disk-full log fix | install-only (from earlier session) |
| `52b52fe` Grant asks macOS | **install-only** — dialog not yet seen by owner |
| Q-88 | spec only, no code |

## Open threads

1. iTerm Automation grant (above) — blocking iTerm features on the Mac.
2. Q-88 US-000 (fake-Mac `wait`/`idle`/`front`/`open`/`lines` commands + `tools/run-fake-mac-tests.sh`): read `tools/fake-mac/fake-mac.swift` (command switch ~1296, `WireWindow` 277, state vars ~514, `handleRequestContent` ~1126); nothing edited. Plan: `stateOverrides`, `closedWindows`, `contentOverrides`, tracked `frontmost` (used by `sendWelcome`), `idle` on a fixture-waiting window → `neutral`, `reload` clears overrides; README command table + `help` + banner list.
3. Optional: log a line when the permission probe flips granted → denied, so the next stale grant is timestamped.

## Resume

Fresh session: "Read docs/superpowers/handoffs/2026-10-29-session-handoff.md, confirm the iTerm Automation grant recovered (injection.log), then build Q-88 US-000."
