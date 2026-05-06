# Session handoff — 2026-05-06 (continuation 5)

Auto-generated at end of cont-5. Supersedes the cont-4 handoff at `df21a32`. Cont-5 closed 5 GH issues + shipped 1 sim-QA bug fix in 6 commits, all pushed to `origin/eb-branch`. **Resume one-liner at the very bottom — paste into a new session after `/clear`.**

---

## Cont-5 commits (all pushed to `origin/eb-branch`)

| Hash | Branch tip | GH | Why |
|------|-----------|-----|-----|
| `3817e2b` | Mac+docs+tests | **#15** closed | CloudflareTunnel Process invocation audit. No shell-injection vector exists (both `Process` invocations use the argv-array form, no shell layer). Refactored argv build into `static cloudflaredArguments(proxyPort:logPath:)` for testability. 7 regression tests in `CloudflareTunnelArgsTests.swift` lock the structure (no `/bin/sh -c`, digit-only port interpolation, verbatim logPath passthrough, argv length=10). Audit doc at `docs/security/2026-05-06-cloudflared-process-audit.md`. |
| `32cb484` | Mac+tests | **#14** closed | PIN UserDefaults→Keychain + entropy raise. New `PINStore` enum mirrors `APNsMetadataStore` (cont-4 462db63). One-shot migration: legacy `QuipAuthPIN` UserDefaults key → service `com.quip.mac.pin` / account `auth`, gated by `pinMigrationV1Done` flag. `PINManager` keeps public API (`pin`, `init`, `regeneratePIN`, `savePIN`) so QuipMacApp / SettingsView / WebSocketServer call sites need no edits. New PINs are 8 digits = ~27 bits = 100M combos; existing 6-digit PINs preserved through migration so paired iOS devices keep working. 11 PINStoreTests cover migration paths + round-trip + entropy + 6-digit preservation. |
| `a9e2c5a` | Mac+iOS+Shared+tests | **#19** closed | Mac→iOS app-level heartbeat. iOS already pings Mac (10s + 3s pong timeout, 2 missed → reconnect); this adds the reverse direction so Mac can detect a wedged-but-TCP-alive iOS app. New `HeartbeatMessage { type: "heartbeat", seq: Int, ts: Double }` + `HeartbeatAckMessage { type: "heartbeat_ack", seq: Int }` in `Shared/MessageProtocol.swift`. Mac side: per-server 15s `Timer` dispatches to authenticated direct-WS clients; tracks pendingHeartbeatSeq + pendingHeartbeatSentAt + lastHeartbeatAckAt per client. Logs a one-line warning to `websocket.log` if heartbeat outstanding past 30s — informational, no aggressive cull (TCP keepalive + pendingBytes backpressure handle that). iOS side: incoming `heartbeat` echoes `heartbeat_ack(seq:)` via existing `send(_:)` Codable path. Tunnel clients out of scope (cloudflared edge handles their liveness). 4 MessageProtocolTests for encoding + round-trip. |
| `f779bd3` | iOS+tests | Bug #1 (sim QA) | `disconnect()` now also clears `lastError` + `connectingStartedAt`. Two-line fix for the cont-3 sim QA repro: fresh-erased simulator showed "Connecting… Stalled 26s — resetting" in top bar simultaneously with "Enter tunnel URL" placeholder in empty-state center — state-machine inconsistency where disconnect cleared isConnecting/isConnected/isAuthenticated but the previous run's watchdog `lastError` lingered. 3 WebSocketClientDisconnectTests cover: lastError cleared on disconnect, connection flags reset, idempotent re-disconnects. |
| `babdc67` | Mac+Shared+tests | **#20** closed | `arrange_windows.layout` String→enum. New `enum ArrangeLayout: String, Codable, Sendable, CaseIterable { case horizontal, vertical }`. ArrangeWindowsMessage.layout converted; Codable rejects unknown rawValues at decode → MessageCoder.decode returns nil → QuipMacApp.swift "arrange_windows" case logs raw payload + broadcasts ErrorMessage instead of silent drop. `LayoutMode.from(arrangeLayout:)` is the new total switch (compiler-enforced exhaustiveness); old `fromArrangeLayout(_:String)` overload kept as `@available(deprecated)` for in-flight callers. Phone-side "grid" stays local (`phoneLayoutOverrideRaw`); wire enum is intentionally restricted. New tests: `RejectsUnknownLayout`, `WireEnumStillRejectsGrid`, `EnumIsExhaustive`, `LegacyStringOverloadStillWorks`. |
| `640b507` | Mac+tests | **#24** closed | APNsMetadataStore + requireAuth lock test coverage — both deferred from cont-4. APNsMetadataStoreTests (8 cases) mirror PINStoreTests for the GH #22 Keychain migration: all-fields migration, partial-legacy fallback to default bundleId, idempotent re-runs, Keychain-pre-populated wins, round-trip per field, empty-string round-trip. WebSocketServerRequireAuthTests (3 cases) lock the OSAllocatedUnfairLock<Bool> contract from GH #21: default fail-safe `true`, setter round-trips, 10k concurrent reads under parallel writer (TSan canary, not deterministic race repro). |

**6 commits, all on `eb-branch`, all pushed to `origin/eb-branch`. 37 commits ahead of main.**

## GitHub issues closed in cont-5

5 closed: **#15** (CloudflareTunnel audit), **#14** (PIN→Keychain), **#19** (Mac→iOS heartbeat), **#20** (arrange_windows enum), **#24** (deferred test coverage).

Combined with cont-4's 5 closures (#18 #23 #25 #21 #22): **10 closed in 2 continuations**.

## Test counts after cont-5

| Suite | After cont-4 | After cont-5 | Delta |
|-------|--------------|--------------|-------|
| QuipMac | 256 | **285** | +29 (+7 CloudflareTunnelArgs +11 PINStore +4 Heartbeat +3 ArrangeLayout +8 APNsMetadataStore +3 RequireAuth-3 ArrangeLayoutMappingTests delta) |
| QuipiOS | 195 (with PhoneLayoutChooser) | **204** | +9 (+4 Heartbeat shared +3 WebSocketClientDisconnect +2 wire-enum tests) |

Both green. Run times: Mac ~20s, iOS ~7s.

## Open GH issues remaining (8)

### CRIT (4) — security audit, all need user input before autonomous burn-down

- **#13** Hardened runtime + DEVELOPMENT_TEAM=D2PM6R797Q. **TCC risk** — rebuild wipes Screen Recording + Accessibility. Hold for maintenance moment.
- **#12** App Sandbox + capability allowlist. Need to enumerate capabilities (AppleEvents, network.client, network.server, file r/w, Bluetooth, mic). Each may break a feature; full retest cycle.
- **#11** Replace `NSAllowsArbitraryLoads` with explicit allowlist. Need host list (`*.trycloudflare.com`, LAN IPs, Tailscale 100.x range, Bonjour `.local`). Some hosts have no fixed pattern.
- **#10** Re-enable TLS pinning for cloudflared. Pin which cert? Cloudflare ICA can rotate; pin to root CA = safe default but defeats the purpose.

### HIGH (2)

- **#17** Per-message HMAC over WS post-PIN. Big lift — derive HMAC key from PIN, every message gets MAC, replay window. Symmetric across Mac+iOS+Watch.
- **#16** Remove 37 MB cloudflared binary from git, fetch at build time. **DO NOT WORK** per memory `feedback_no_filter_repo_main_conflict.md` — would compound PR #29 hash mismatch.

### Other

- **#26** META tracker — parent of audit-2026-04 work.
- **#4** QuipLinux: wire up duplicate_window / close_window from phone.

## Branch memory updates this session

- New `feedback_no_filter_repo_main_conflict.md` — locks GH #16 filter-repo and PR #29 path A as do-not-do until PR #29 is resolved. User explicit on 2026-05-06: "I don't wanna do anything that conflicts with Main." Paths B (cherry-pick onto fresh branch) and C (squash-merge via UI) remain on the table when user decides to merge.

## PR #29 status (carry-forward — unchanged)

Still **CONFLICTING** against main. Hash mismatch from cont-2's `git filter-repo` rewrite (`71af40e` → `e839a2b`). Resolution paths still:

- ~~**A** force-push main with rewritten history~~ — **OFF the menu** per user policy
- **B** cherry-pick cont-3+4+5 commits onto a fresh branch off current main — loses the device-name redaction in main's history
- **C** squash-merge via GitHub UI — collapses everything into one commit on main, hash mismatch becomes irrelevant

User picks B or C when ready to merge.

## Wishlist active items (12)

| § | What | Notes |
|---|------|-------|
| §0c | PTT recognizer Settings picker + Whisper model-size selector | leverage §15 v2 sectioned-Settings pattern |
| §4 | `/plan` button cross-platform parity | Watch + iPhone parity |
| §5 | `/plan` button v2 — optional auto-dictation | depends §0b/§0c |
| §18 | Context-aware 1/2/3 buttons | terminal-content scrape |
| §24 | Crash recovery for QuipMac via launchd LaunchAgent | macOS LaunchAgent plist |
| §26 | Diagnostic-capture gesture on iPhone | shake / 3-finger gesture → bundle upload |
| §30 | Reliability & UX hardening pass (5-thread backlog) | grouped follow-ups |
| §35 | Cross-app paste from iPhone clipboard into Quip terminal | iOS pasteboard → sendText |
| §38 | iTerm scrollback navigation from iPhone | scroll cmd protocol |
| §56 | Voice macros — "ship it" → multi-step | open UX shape |
| §B15 | iPhone a11y — slot-row chips + reset/close labels | partial — main-row done in cont-4 |
| §B17 | Trace `type=unknown (4 bytes)` frame | diagnostic shipped, **capture pending** — phone reconnect needed |

Bug #1 (cont-5 `f779bd3`) is NOT yet flipped to ✅ Done in wishlist — it was a sim-QA bug not previously filed there. Could add a Done entry for traceability in next session.

## Hardware-verified ✅ vs install-only ⚠️ (cont-5)

**Verified live this session:**
- All cont-5 work is unit-test verified (29 new Mac tests + 9 new iOS tests, all green).

**Install-only — needs your eyes:**
- Bug #1 fix — fresh-erase a sim, launch Quip with no URL: top bar should NOT show "Stalled Ns — resetting" alongside "Enter tunnel URL" placeholder.
- §B17 capture — `tail -F ~/Library/Logs/Quip/kokoro.log | grep §B17` after phone reconnects through the post-462db63 Mac. The first unknown frame's UTF-8 + hex bytes will identify the iOS sender.
- All cont-4 Story 11 punch list (carryforward — VoiceOver swipe / arrange-cycle / drag-snap / requireAuth-race / Keychain-migration smoke) — physical iPhone 17 Pro Max still on cont-4 build (databaseSequenceNumber 9524), needs force-quit + relaunch.
- New cont-5 features: PIN→Keychain migration on hardware (`security find-generic-password -s "com.quip.mac.pin" -g` should show entry; `defaults read com.quip.mac QuipAuthPIN` should error). Heartbeat round-trip on hardware (Mac websocket.log should show outbound heartbeats every 15s; tail kokoro.log for `heartbeat_ack` arriving from phone).

## Install state (cont-5)

| Surface | Build identity | Notes |
|---------|---------------|-------|
| `/Applications/Quip.app` | NOT rebuilt this continuation — still on cont-4 tip mtime ~11:01 PT | All cont-5 Mac changes need a rebuild + re-sign + ditto for hardware verification |
| iPhone 17 Pro Max physical | Still on cont-4 build (databaseSequenceNumber 9524) | Bug #1 fix + heartbeat ack + arrange enum need a fresh install |
| Quip QA sim (D853A014) | Auto-installed during test runs (`xcodebuild test`) | Cont-5 changes are present in the test bundle but not necessarily in a UI-launchable build of the app |

## What this continuation deliberately did NOT do

- No filter-repo / force-push on `main` per user policy memo (committed to memory mid-session).
- No CI lint expansion — 186k swiftformat + 300 cargo fmt debt still outstanding from cont-3 plan.
- No Story 11 punch-list verification — needs your hardware + eyes.
- No §B17 capture — needs phone reconnect.
- No wishlist update for Bug #1 — leave for next session.
- No #13/#12/#11/#10 critical-security work — each needs explicit user decisions before autonomous attempt.
- No #17 HMAC — high-effort multi-platform symmetric work.
- No #4 QuipLinux duplicate/close — Linux-side work, separate stack.

## Open threads (priority for resume)

1. **Force-quit + relaunch Quip on iPhone**, then run cont-4 Story 11 punch list AND cont-5 verification:
   - VoiceOver swipe through main view (cont-4 Story 3)
   - Spawn 3rd window → vertical; 4th → grid (§39 v2)
   - Drag a window to right edge → snap (§40)
   - Tap arrange 3× → horizontal/vertical/grid cycle (§16)
   - Toggle requirePIN setting on Mac while phone is connecting → no misroute (#21)
   - `security find-generic-password -s "com.quip.mac.apns-metadata" -g` shows entry; `defaults read com.quip.mac apnsKeyId` errors (#22)
   - **NEW for cont-5:** `security find-generic-password -s "com.quip.mac.pin" -g` shows entry; `defaults read com.quip.mac QuipAuthPIN` errors (#14)
   - **NEW for cont-5:** Bug #1 — fresh-erase a sim, launch with no URL: no "Stalled Ns" + "Enter tunnel URL" contradiction
   - **NEW for cont-5:** Heartbeat — Mac log shows 15s heartbeat dispatch; phone responds with heartbeat_ack
2. **Capture §B17 trace** — tail kokoro.log after phone reconnect; first unknown-bytes log identifies iOS sender; write iOS-side fix.
3. **Pick PR #29 resolution** — paths B or C (A is permanently off per memory).
4. **CI lint strategy** — (a) defer / (b) advisory `continue-on-error: true` / (c) mass-format commit.
5. **Tier-2 GH critical-security** (when ready, with user decisions):
   - #11 ATS allowlist — needs host list approval
   - #10 TLS pinning — needs cert strategy decision
   - #12 App Sandbox — needs capability matrix decision
   - #13 hardened runtime — needs maintenance window for TCC re-grants
6. **#17 HMAC** — needs design discussion.

## Resume one-liner (cont-5)

> Continue Quip on `eb-branch` from `640b507`. Cont-5 closed 5 GH (#15 #14 #19 #20 #24) + fixed sim-QA Bug #1, all 6 commits pushed to `origin/eb-branch`. **+29 Mac tests (285 total) + 9 iOS (204 total). 37 commits ahead of main.** New branch memory `feedback_no_filter_repo_main_conflict.md` blocks GH #16 filter-repo + PR #29 path A (force-push main); paths B/C still on table for merge. **Hardware unverified:** Bug #1, PIN Keychain migration, heartbeat round-trip, all cont-4 Story 11 punch list. **§B17 still unresolved** — capture pending on phone reconnect. PR #29 conflict still open. Remaining open issues: 4 CRIT (#10 #11 #12 #13), 2 HIGH (#16 do-not-touch + #17 HMAC), #26 META, #4 Linux. /Applications/Quip.app at cont-4 mtime ~11:01 PT 2026-05-06 (cont-5 Mac changes need rebuild for hardware). iPhone 17 Pro Max physical still on cont-4 databaseSequenceNumber 9524 (needs force-quit + relaunch). Remaining wishlist active: §0c §4 §5 §18 §24 §26 §30 §35 §38 §56 §B15-partial §B17.
