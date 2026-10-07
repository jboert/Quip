# Session handoff addendum 3 — 2026-10-07 (evening): QA-fix batch, a settings overwrite, push down

Read this before touching eb-branch. It continues the two addenda from earlier today.

## Where the branch is

- eb-branch is 44 commits ahead of origin and **not pushed** (the owner has not said "push").
- Landed this evening, phone side of the QA-fixes PRD (`tasks/prd-qa-fixes-2026-10-07.md`, gitignored):
  - `d699975` — the phone ignores a preferences restore meant for another device (`PreferenceRestoreMessage.deviceID`, Shared, additive) and clears "Auth failed" after a good PIN (US-004, phone half of US-014).
  - `7d2cd49` fill hint back on prompt rows (US-001); `89ed80b` editor footer tells the truth (US-003); `2f01289` search keeps case (US-007); `dc6a8db` `PlainTextEditor` keeps straight quotes (US-002); `e92806a` "Attached" right away (US-006).
  - `f308b7d` — the phone app never connects to a Mac when it runs as the XCTest host (`TestHostGuard`, checked in `BackendConnectionManager.bootstrap()`). See the incident below for why.
  - Gate: `QUIP_QA_SIM_UDID=D8C5154B-7030-40BA-8443-F4F9EB27C725 tools/check.sh` ran green on the full tree (swiftc harness 62 checks, QuipMac 994 tests, QuipiOS 951 tests), and the pre-commit hook re-ran the QuipiOS suite green on `f308b7d`.
- Still open from the PRD: US-005 and US-012 (phone connection: PIN carry-over, dead-address failover) and the Mac batch US-008 to US-011 plus the Mac half of US-014. Both were handed to in-tree workers at the end of this session; check `git log` for their commits and the worker reports in the session transcript. Each worker was told to leave `QuipiOS/QuipApp.swift` alone; the phone worker returns one-to-three-line wiring edits for US-005 step 4 and US-012 step 6 that the integrator applies.
- Not yet installed anywhere. The phone install waits for the owner to finish voice testing (the relaunch would cut their session). The Mac install also carries the pending Q-45 `quickSlotColorsJSON` backup field and costs an Accessibility and Screen Recording re-grant.

## Incident: the owner's phone settings were overwritten (US-014 in the wild)

At 22:05:44Z the `tools/check.sh` iOS suite launched Quip as the XCTest host on the shared QA simulator (`9A204976-…`). That simulator was still paired with the Mac from the morning's QA pass and had the PIN cached, so the host app authenticated and sent `preferences_request`; the Mac (still the old build) broadcast the simulator's snapshot to every client, including the owner's phone. Evidence: `websocket.log` `client live: <mac-lan-ip>:65028 (auth=pin)` at 22:05:44Z, and the Mac's backup for the owner's phone (`defaults read com.quip.mac` key `phonePrefs.B79E1FB4-…`) now holds the fresh-install default row `btw · yes no · one two · esc backspace clearInput` with one custom button (/help), while the owner's real row survives under `phonePrefs.A10A66FB-…` (23 keys, custom buttons Y, 3, p, `promptUsageJSON`): `slash compact · btw Y no · one two 3 · clearInput esc · p backspace plan · ctrlC`. The round-2 simulator sessions earlier in the day may have done the same before this.

**Restore recipe (only after the owner says "restore buttons"):** `defaults export com.quip.mac -` → plistlib → JSON-decode both blobs; copy `quickSlotsJSON`, `customButtonsJSON`, `enabledQuickButtons` and `promptUsageJSON` from `A10A66FB-…` into the `B79E1FB4-…` JSON, keep every other field of `B79E1FB4-…`; write back with `defaults write com.quip.mac phonePrefs.B79E1FB4-… -data <hex>`; then the owner force-quits and relaunches the phone app while it is the only connected device, and it pulls its own backup. The phone's text size may be 10 now (hold the A button to reset).

**Prevention:** Quip is uninstalled from the shared simulator; `TestHostGuard` (f308b7d) stops the host app from dialing at all; every gate run uses `QUIP_QA_SIM_UDID=D8C5154B-…` (the erased Quip-only simulator, never paired). Still worth doing: make `tools/check.sh` default to that UDID.

## Push notifications are down

`~/Library/Logs/Quip/push.log`: every event today is `waiting_for_input skipped — APNs not configured in Settings → Notifications` (about 11,950 lines). Known pattern after a Mac reinstall: the APNs key item in the Keychain is orphaned. Owner fix now: Mac Quip Settings → Notifications, re-enter the .p8 key. A read-only worker was tracing when it broke and the durable fix (team-scoped keychain access group); see its report in the transcript or redo it, then add a Mac story to the board.

## Voice findings

- `phone.log` has zero `ptt start` lines today; the owner's dictation came from the iOS keyboard mic, not Quip's PTT. The two owed voice checks (Q-38a SpeechAnalyzer, Q-39a Whisper jargon) still need a Quip PTT press.
- SpeechAnalyzer never engages on the phone: every launch logs `analyzer readiness=unsupported locale=none` (`AnalyzerAssets.readiness`, `QuipiOS/Services/AnalyzerSession.swift`; the caller in `SpeechService.swift` cannot tell which guard failed). A read-only worker was checking the iOS 26 API and proposing a diagnostic line plus a fix; ship the diagnostic with the phone batch.
- The 21:21Z–21:38Z handshake storm "from" the Mac's own Tailscale address was almost certainly the Quip-only simulator dialing the Mac's own Tailscale URL after it absorbed the owner's `pairedBackendsJSON` through the same restore broadcast. Not a foreign device; closed.

## Tooling note

Agents launched with worktree isolation were based on `origin/main`, not eb-branch, and the harness kept switching this session's working directory into their worktrees (Write and `git -C` to the main checkout were refused). All worktree agents were stopped and their worktrees removed; the remaining workers run in the main checkout with disjoint write sets. Do not use worktree isolation for agents in this repo until that is understood.

## Owner calls still open

- "restore buttons" (recipe above) after checking Settings → Quick Buttons on the phone.
- Re-enter the APNs .p8 key in Mac Settings → Notifications.
- "push" for eb-branch; "install" for the phone batch once voice testing is over.
- Two feature requests dictated this evening, to be specced: better search for quick buttons and prompts (board Q-47) and a broadcast button like VibeCut's. A read-only comparison of VibeCut's broadcast button with Quip's `broadcastPromptButton` / `BroadcastPromptSheet` was running at the end of the session.
- Q-43 voice mode, Q-36, Q-32a; GH #37 after hardware verification.
