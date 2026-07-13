# Session handoff — 2026-07-12

## Resume command

> "Read docs/superpowers/handoffs/2026-07-12-session-handoff.md. The AppleScript
> crash fix is committed but NOT yet installed to /Applications — finish the
> QuipMac test suite, rebuild Release, ditto to /Applications, then have me
> exercise multi-select in Terminal.app while you tail the logs."

## Commits this session

| Hash | Why |
| --- | --- |
| (this commit) | `fix(mac): serialize every NSAppleScript through one queue` — kills the SIGSEGV described below, plus a stress test and an in-flight gate on the window poll. |

Earlier commits on `eb-branch` (from the prior session, pushed to origin today at
the user's explicit request):

| Hash | Why |
| --- | --- |
| `de78f95` | docs: wishlist — dictation/multi-select shipped, acceptance + deferred items |
| `6a3ff24` | fix(ios): remote PTT gets pre-roll + longer timeout + caption fallback |
| `be24f3b` | feat(mac): Whisper model base → small.en for remote PTT |
| `2781b65` | feat: dictation vocab covers AI model names; corrector fixes bare 'codex' |
| `bf050c7` | fix(mac): Terminal.app keystroke path can press space — unbreaks multi-select |

## Install state

- **Mac** — `/Applications/Quip.app` is **v1.5.5, PRE-crash-fix**. It was
  reinstalled from `de78f95` early in the session (Developer ID, team
  `D2PM6R797Q`, fresh pid verified). The AppleScript fix in this commit is
  **built and tested but NOT installed** — next session must rebuild Release and
  `ditto` it in.
- **iPhone (iPhone 17 Pro Max)** — Debug build of `6a3ff24` installed via
  `devicectl`. Current.
- **Quip is not running** as of this handoff — it was killed for the app-hosted
  test run and deliberately left down so the test host could bind 8765.
  Relaunch `/Applications/Quip.app` once the suite is done.

## Verified vs install-only

| Thing | Status |
| --- | --- |
| AppleScript serialization (`AppleScriptRunner`) | **Verified in test**: 3/3 concurrency tests pass (200-way `concurrentPerform`, main-vs-background overlap, malformed-script recovery). Release builds clean under Swift 6. **Not** verified on hardware — not installed yet. |
| Latency cost of serializing | **Measured on this Mac** against live iTerm2: `fetchSubtitles` 186ms, `fetchIterm2SessionIds` 208ms, `readContent` 91ms/window → queue busy ~15-20%, worst-case keystroke wait ~200ms. Acceptable; no rework needed. |
| Terminal.app multi-select space key (`bf050c7`) | **Install-only — STILL UNVERIFIED ON HARDWARE.** This was the thing the user sat down to test and we never got to it. |
| Remote PTT pre-roll (`6a3ff24`) | Install-only. |
| Whisper small.en (`be24f3b`) | Install-only. |

## Open threads

1. **Finish the QuipMac test suite.** It is running with
   `-skip-testing:QuipMacTests/APNsJWTTests`; result not yet seen at handoff
   time. The targeted concurrency tests already pass.
2. **`APNsJWTTests` hangs the whole suite — new finding, separate bug.**
   `APNsJWTTests.setUpWithError()` → `APNsKeyStore.get()` (`APNsKeyStore.swift:62`)
   blocks in `mach_msg2_trap` for as long as you let it (57 min observed),
   waiting on a **Keychain authorization prompt**: the Debug test host has a
   different signature than `/Applications/Quip.app`, so the Keychain treats it
   as a stranger. Makes `xcodebuild test` unrunnable unattended. Fix candidates:
   team-scoped `kSecAttrAccessGroup` (already on the wishlist for the
   resign-orphan problem), or have the test skip when the key can't be read
   without a prompt.
3. **Multi-select acceptance test.** Terminal.app + Claude Code checkbox prompt,
   select 2+ options from the phone, Submit. Logs to tail:
   `~/Library/Logs/Quip/websocket.log`. Check `netstat -an | grep 8765` for a
   single ESTABLISHED socket first.
4. **APNs push is dead on this Mac** — `push.log` repeats "waiting_for_input
   skipped — APNs not configured in Settings → Notifications". Expected after the
   reinstall (keychain `.p8` orphans on resign). Re-enter the `.p8` in
   Settings → Notifications when push matters.
5. **The crash fix is not reproduction-proven.** See the wishlist entry: 260
   unserialized concurrent compiles survived in a standalone harness, so the race
   window is narrow. If Quip segfaults again, pull the new `.ips` — if the
   faulting thread is still inside AppleScript, the serialization theory is wrong
   and the next suspect is the OSA component instance itself.

## Not pushed

`eb-branch` was pushed to origin earlier today when the user explicitly asked.
**This commit has not been pushed** — per standing policy, pushes need the user
to ask for them.
