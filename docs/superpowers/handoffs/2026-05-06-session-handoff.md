# Session handoff — 2026-05-06

Auto-written at ~50% context per `feedback_recap_at_50pct.md`. Supersedes `2026-05-06-continuation-5-handoff.md` (`7481360`) — same content, canonical filename. **Resume one-liner at the very bottom.**

---

## Today's commits (7 total, all pushed to `origin/eb-branch`)

| Hash | GH | Why |
|------|-----|-----|
| `3817e2b` | **#15** closed | Mac: CloudflareTunnel `Process` invocation audit. No shell-injection vector — both call sites use argv-array form, no shell layer. Refactored argv build into `static cloudflaredArguments(proxyPort:logPath:)` for testability. 7 regression tests in `CloudflareTunnelArgsTests.swift`. Audit doc at `docs/security/2026-05-06-cloudflared-process-audit.md`. |
| `32cb484` | **#14** closed | Mac: PIN UserDefaults→Keychain. New `PINStore` enum mirrors `APNsMetadataStore` from cont-4. One-shot migration: legacy `QuipAuthPIN` → service `com.quip.mac.pin` / account `auth`. New PINs are 8 digits = ~27 bits = 100M combos; 6-digit legacy PINs preserved through migration so paired iOS devices keep working. 11 PINStoreTests. |
| `a9e2c5a` | **#19** closed | Mac+iOS+Shared: Mac→iOS app-level heartbeat. New `HeartbeatMessage`/`HeartbeatAckMessage` in `Shared/MessageProtocol.swift`. Mac: 15s `Timer` per server dispatches to authenticated direct-WS clients; logs to websocket.log if outstanding past 30s (informational, no aggressive cull). iOS: incoming `heartbeat` echoes `heartbeat_ack(seq:)` via existing `send(_:)` Codable path. Tunnel clients out of scope. 4 MessageProtocolTests. |
| `f779bd3` | Bug #1 (sim QA) | iOS: `disconnect()` now also clears `lastError` + `connectingStartedAt`. Two-line fix for cont-3's sim-QA repro (top bar showed "Stalled 26s — resetting" simultaneously with "Enter tunnel URL" placeholder). 3 WebSocketClientDisconnectTests. **Install-verified** on QA sim (D853A014) at t=40s — no stale watchdog text leaks into UI. |
| `babdc67` | **#20** closed | Mac+Shared: `arrange_windows.layout` String→`enum ArrangeLayout`. Codable now rejects unknown rawValues at decode → `MessageCoder.decode` returns nil → `QuipMacApp.swift` `case "arrange_windows":` logs raw payload + broadcasts `ErrorMessage` instead of silent drop. `LayoutMode.from(arrangeLayout:)` is the new total switch. Phone-side "grid" stays local — wire enum is intentionally `{horizontal, vertical}`. New tests: rejects unknown / rejects grid / enum-exhaustive / legacy-string-overload. |
| `640b507` | **#24** closed | Mac: APNsMetadataStore + requireAuth lock test coverage (deferred from cont-4). 8 APNsMetadataStoreTests mirror PINStoreTests; 3 WebSocketServerRequireAuthTests lock the `OSAllocatedUnfairLock<Bool>` contract with a 10k concurrent-read TSan canary. |
| `7481360` | n/a | Cont-5 handoff doc + branch-memory entry `feedback_no_filter_repo_main_conflict.md` (locks GH #16 + PR #29 path A as do-not-do per user policy). |

5 GH closed (#15 #14 #19 #20 #24). +29 Mac tests (256→**285**). +9 iOS tests (195→**204**). 38 commits ahead of `main`. All pushed.

## Install state

| Surface | Build | Notes |
|---------|-------|-------|
| `/Applications/Quip.app` | Cont-4 build (CFBundleShortVersionString 1.5.1, mtime ~11:01 PT 2026-05-06) | **Cont-5 Mac changes need rebuild + re-sign + ditto for hardware verification** (heartbeat dispatch, PIN→Keychain, requireAuth lock — none currently running on installed Mac app) |
| iPhone 17 Pro Max physical | Cont-4 build (databaseSequenceNumber 9524) | Force-quit + relaunch + reinstall needed to pick up: Stories 3-6 (cont-4) AND Bug #1 / heartbeat ack / arrange enum (cont-5) |
| Quip QA sim (`D853A014-...`) | Cont-5 fresh build (Debug, /tmp/quip-bug1-build) | **Bug #1 install-verified ✅** at t=40s post-launch — no stale "Stalled Ns" text. Other cont-5 features (heartbeat, PIN migration) not exercised in sim — needs paired Mac. |

## Hardware-verified ✅ vs install-only ⚠️

**Verified live this session (autonomous):**
- All cont-5 logic — 38 unit/integration tests across new files, all green.
- **Bug #1** — install-verified on QA sim. Fresh erase → build → install → launch → 40s wait → no stale watchdog text. Screenshot at `/tmp/bug1-t40.png`.

**Install-only — needs your eyes:**
- Cont-4 Story 11 punch list (carryforward) — VoiceOver swipe / arrange-cycle / drag-snap / requireAuth-race / Keychain-migration smoke.
- Cont-5 PIN→Keychain on real Mac — `security find-generic-password -s "com.quip.mac.pin" -g` shows entry; `defaults read com.quip.mac QuipAuthPIN` errors.
- Cont-5 heartbeat round-trip on real Mac+phone — websocket.log shows 15s heartbeat dispatch; kokoro.log shows incoming heartbeat_ack.
- Cont-5 arrange enum — phone tap arrange 3× → cycle horizontal/vertical/grid (grid is phone-local; Mac handler still gets only horizontal/vertical).
- §B17 capture — `tail -F ~/Library/Logs/Quip/kokoro.log | grep §B17` after phone reconnects to post-462db63 Mac.

## Open threads (priority for resume)

1. **Rebuild Mac + reinstall iPhone**, then run combined cont-4 Story 11 + cont-5 verification punch list (full list in this doc above).
2. **Capture §B17 trace** — `tail -F ~/Library/Logs/Quip/kokoro.log | grep §B17` after phone reconnect; first unknown-bytes log identifies iOS sender; write iOS-side fix.
3. **PR #29 resolution** — paths B (cherry-pick onto fresh branch) or C (squash-merge via UI). Path A is **off the menu** per `feedback_no_filter_repo_main_conflict.md`.
4. **CI lint strategy** — (a) defer / (b) advisory `continue-on-error: true` / (c) mass-format commit. 186k swiftformat + 300 cargo fmt debt unchanged.
5. **Tier-2 GH** when ready (need user decisions per issue): #11 ATS allowlist (host list) · #10 TLS pinning (cert strategy) · #12 App Sandbox (capability matrix) · #13 hardened runtime (TCC re-grant window) · #17 HMAC (design discussion).
6. **#16 cloudflared filter-repo** — **DO NOT WORK** per user policy memo; would compound PR #29's existing hash mismatch.

## Wishlist still active (12)

§0c PTT recognizer Settings · §4 /plan cross-platform parity · §5 /plan v2 auto-dictation · §18 context-aware 1/2/3 buttons · §24 launchd crash recovery · §26 diagnostic-capture gesture · §30 reliability hardening · §35 cross-app paste · §38 iTerm scrollback · §56 voice macros · §B15 a11y slot-row chips/reset/close · §B17 4-byte trace capture pending.

Bug #1 (cont-5 `f779bd3`) is now install-verified but **not yet flipped to ✅ Done in `wishlist.md`** — it was a sim-QA bug not previously filed there. Add a Done entry next session for traceability.

## Branch memory updates this session

- New `feedback_no_filter_repo_main_conflict.md` — locks GH #16 filter-repo + PR #29 path A (force-push main) as do-not-do until PR #29 is resolved. User explicit on 2026-05-06: "I don't wanna do anything that conflicts with Main." Paths B/C remain on the table for merge.

## Resume one-liner

> Continue Quip on `eb-branch` from `7481360`. Today shipped 6 GH-closing commits + Bug #1 fix + handoff: #15 (CloudflareTunnel audit), #14 (PIN→Keychain + 8-digit), #19 (Mac→iOS heartbeat), Bug #1 (disconnect clears stale lastError, **install-verified on QA sim**), #20 (arrange_windows enum), #24 (deferred test coverage). Mac suite 285 / iOS 204, both green. 38 commits ahead of main, all pushed to origin/eb-branch. Branch memory `feedback_no_filter_repo_main_conflict.md` blocks GH #16 filter-repo + PR #29 path A; paths B/C still on table. **/Applications/Quip.app and physical iPhone are still on cont-4 builds — cont-5 Mac/iPhone features need rebuild + reinstall + force-quit before hardware verification.** Combined cont-4 Story 11 + cont-5 punch list pending: VoiceOver / arrange-cycle / drag-snap / requireAuth-race / Keychain-migration / heartbeat round-trip / Bug #1 fresh-launch on real hardware. §B17 trace capture pending on phone reconnect. Open GH: 4 CRIT (#10 #11 #12 #13) need user decisions, #17 HMAC big lift, #16 do-not-touch, #26 META, #4 Linux. PR #29 still conflicting; resolve via B or C only.
