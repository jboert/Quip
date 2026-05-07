# Session handoff — 2026-05-06 (continuation 8)

Auto-written end of session per `feedback_recap_at_50pct.md`. **Supersedes cont-7 handoff (`5caa1e7`)** — that doc covered through `5caa1e7`. Continuation 8 shipped Phase 2 of smart-signal latency (separately by user) plus all of Phase 3 (3 commits + spec revision) plus answered "what did I just do" / Tailnet Lock setup. **Resume one-liner at the very bottom.**

---

## This session's substantive commits (10)

In rough chronological order. Mix of user-driven Tailnet Lock work, Phase 2 by user, then Phase 3 series:

| Hash | Why |
|------|-----|
| `cc3bddc` | iOS: **§30/4 — loud-drop helper for WebSocket message decode.** 22 silent `try? decoder.decode(...)` sites in `WebSocketClient.handleMessage` now route through `Self.decodeMessage(_:from:msgType:log:)`. Failures emit `[WebSocketClient] decode FAILED type=<wire-tag> kind=<Swift.Type> bytes=<N> err=<...>`. 6 tests. |
| `6aca7d8` | Mac+iOS: **§30/4 encode-side — name the message TYPE in encode-error logs.** `WebSocketServer.broadcast<T>` + `WebSocketServer.send<T>` (Mac) + `WebSocketClient.send<T>` (iOS) now log `kind=<Swift.Type>`. iOS `send` signature flipped from `some Codable` → `<T: Codable>(_ message: T)` so `T.self` is in scope. |
| `5caa1e7` | **cont-7 handoff** (committed by this session). |
| `06d133b` | **Spec: latency-driven load balancing across paired backends.** Phase 3 design doc — original draft (across-Macs target). |
| `abb89a9` | **Latency Phase 2: SendTextAck round-trip + friendly Settings sheet.** (User-driven, not me.) Round-trip ack from Mac, iOS LatencySample 100-deep buffer, friendly sparkline UI. |
| `49160d5` | **Latency Phase 3/1: observational widening.** Adds `transport` (.localWS / .cloudflareTunnel / .unknown), `networkClass` (.wifi / .cellular / .wired / .unknown), and `netVariance` (population std-dev of last 10 same-transport netRtt) to `LatencySample`. NSLog gains `transport=X net=Y var=Z`. 14 tests. |
| `bab9aad` | **Spec revision: latency load-balance targets URLs (same Mac), not Macs.** Architecture review: across-Macs is wrong because each Mac has its own terminal state. Common deployment is ONE Mac with multiple paths (Bonjour LAN, Tailscale CGNAT, Cloudflare tunnel) in `urlsInOrder`. Phase 3 retargeted to hot-swap reconnect across URLs to same Mac. |
| `f6d70cc` | **Latency Phase 3/2: per-URL sample bucketing.** Adds `serverURLHost: String` to `LatencySample`. Transport class alone lumps Bonjour LAN (192.168.x.x) and Tailscale CGNAT (100.x.x.x) into the same `.localWS` bucket — URLSwapPolicy needs per-host bucketing. 1 new test, retagged 14 existing. |
| `d102f2c` | **Latency Phase 3/3: probe + URLSwapPolicy + hot-swap orchestration.** Closes Phase 3. New: `LatencyProbeService` (60s NWConnection probes against alt URLs, 5s timeout), `URLSwapPolicy.decide(...)` (max 1 swap/5min, candidate must beat current by 30%, last 3 samples must each beat current — defends against fluky single-sample wins), `BackendConnectionManager.evaluateSwap()` orchestrator (30s tick, calls policy, performs disconnect → reorder urlsInOrder in-memory → primePIN → reconnect). Settings toggle in Latency sheet, **default OFF**. 16 URLSwapPolicyTests. |

Plus the Tailnet Lock setup walkthrough (no commit — that was a runtime config on the user's tailnet itself). Also the Gmail draft for the user explaining tailnet lock conceptually (drafted, not sent).

---

## Pre-session commits since cont-7 handoff (1, NOT this session)

| Hash | Why |
|------|-----|
| `863ee28` | **Mac: instrument send_text → latency.log (smart-signal Phase 1).** User-driven before this session opened. Established the Mac-side timing source that Phase 2 round-tripped to iOS. |

(That was actually pre cont-7. The inter-handoff window for this cont-8 was clean.)

---

## Test counts

| Suite | Start of cont-8 | End of cont-8 | Δ |
|-------|------------------|----------------|---|
| QuipMac | 317 | **317** | 0 (no Mac source change Phase 3; only the §30/4 encode-side 4-line log format edit landed on Mac and unit tests already cover that log site) |
| QuipiOS | 304 | **341** | +37 (DecodeMessageHelperTests 6, LatencyTaggingTests 15, URLSwapPolicyTests 16) |
| **Combined** | **621** | **658** | **+37** |

Both green. Mac 23s, iOS 7.5s. iOS suite ran on QA sim D853A014.

---

## Install state (end of session)

| Surface | Build | Mtime | Notes |
|---------|-------|-------|-------|
| `/Applications/Quip.app` | **1.5.2** | 2026-04-16 (per `stat`) | NOT REINSTALLED THIS SESSION. The encode-side log format edit (`6aca7d8`) is in source only — host /Applications copy still on the cont-6/7 binary. Mac source tests cover the log line format adequately; no on-host behavior depends on it. Per `feedback_mac_rebuild_cost.md`, no rebuild — only cosmetic log change. |
| iPhone physical | **1.5.4** (cont-6/7 install) | databaseSequenceNumber 9540 | NOT REINSTALLED THIS SESSION. Phase 3 helper + probe service + policy + Settings toggle are all in source only. **Force-quit + reinstall pending** before any of Phase 2/3 latency work shows on the phone. |
| QA sim D853A014 | post-`d102f2c` build | DerivedData | Test-only build during `xcodebuild test`. Not a feature install. |

**Hardware-verified ✅ vs source-only ⚠️ this session:**
- ✅ DecodeMessageHelperTests pass on QA sim
- ✅ LatencyTaggingTests pass on QA sim
- ✅ URLSwapPolicyTests pass on QA sim
- ✅ Full QuipiOS suite (341/341) on QA sim
- ✅ Full QuipMac suite (317/317) on macOS host
- ✅ Tailnet Lock enabled on user's tailnet (live `tailscale lock status` → ENABLED, 2 trusted signers: mac-studio23 + iphone182). Disablement secret captured by user in password manager.
- ⚠️ §30/4 decode helper behavior on physical iPhone — not deployed
- ⚠️ §30/4 encode-side log format on Mac — not deployed
- ⚠️ Phase 2 latency UI on physical iPhone — not deployed
- ⚠️ Phase 3 probe + swap on physical iPhone — not deployed; toggle defaults OFF anyway, so even after install nothing happens until user opts in
- ⚠️ Cellular roam → networkClass updates in samples — needs phone+install+roam test
- ⚠️ Hot-swap blip behavior under Network Link Conditioner — full-pipeline integration test pending

---

## Wishlist active items remaining (post-session)

| § | What | Notes |
|---|------|-------|
| §0c | PTT recognizer Settings picker + Whisper model-size | depends §0b acceptance + §15 v2 sectioned-Settings |
| §5 | `/plan` v2 auto-dictation | needs UX shape decision |
| §30 | Reliability — threads #3 (lifecycle invariants) + #5 (notification triage view) | half-eaten meta tracker; #1/#2/#4 shipped earlier in cont-7 |
| §56 | Voice macros | open UX shape |
| §B15 | a11y remaining | quick verify; re-run audit script |
| §B17 | unknown-frame trace | diagnostic in code; capture pending phone reconnect to post-462db63 Mac |
| **NEW: latency hot-swap hardware verify** | Phase 3/3 toggle OFF → on; throttle Cloudflare via Network Link Conditioner; confirm `[Quip][LATENCY] hot-swap: from=X to=Y` in log; confirm sub-second §K blip; roam Wi-Fi→cellular and verify networkClass switch | Defer until phone has been reinstalled to a build containing Phase 2 + Phase 3 |

Wishlist file itself was not edited this cont-8 session (cont-7 already substantively rewrote §30 — no further updates due). Latency hot-swap belongs as a new entry; **deferred to next session** since the work is fresh and shouldn't be filed away as wishlist while it's still actively being verified.

---

## Open threads (priority for resume)

1. **Reinstall cycle for the entire latency stack.**
   - Build + install QuipMac (1.5.2 source post-`6aca7d8` — ditto into /Applications, re-sign with stable cert per `reference_quip_install_recipe.md`).
   - Build + install QuipiOS to the user's iPhone 17 Pro Max (per `feedback_default_install_device.md`). Bump CFBundleShortVersionString past 1.5.4 if doing manual QA differentiation.
   - Force-quit iPhone Quip after install (per `feedback_default_install_device.md`).
2. **Phase 2 + Phase 3 hardware verify.** Tap a few send_text messages with Codex pasteText and Claude sendText; inspect the new Settings → Diagnostics → Latency sheet — see badges + medians + sparkline. Confirm probe samples appear in latency.log when on a multi-URL backend. Flip "Auto-pick fastest path" ON; throttle one URL to confirm hot-swap fires + log line emits.
3. **Hardware verification punch list still pending from cont-6/7.** §24 LaunchAgent, §30/2 DisconnectReason, §26 shake, §J/K/L. None blocked, just needs phone-in-hand session.
4. **§30 threads #3 (lifecycle invariants) + #5 (in-app notification triage view)** — still wishlist; #1/#2/#4 shipped.
5. **PR #29** — paths B (cherry-pick onto fresh branch) or C (squash-merge via UI). Path A locked off per memory.
6. **Tier-2 GH security tickets** — #11 ATS allowlist · #10 TLS pinning · #12 App Sandbox · #13 hardened runtime · #17 HMAC. All need user decisions.
7. **CI lint debt** — 186k swiftformat + 300 cargo fmt unchanged. Still (a) defer / (b) advisory continue-on-error / (c) mass-format commit.

---

## Memory updates this session

None required this cont-8.
- `feedback_eb_branch_push_policy.md` honored — committed locally only; no `git push` despite stop-hook auto-prompt.
- `feedback_commit_discipline.md` honored — 4 separate Phase 3 commits (1/3, spec revision, 2/3, 3/3) + 2 §30/4 commits + 1 spec + 1 handoff. Each is a self-contained release note.
- `feedback_autonomous_brainstorm_execute.md` honored — drove §30/4 audit + Phase 3 design + 3-commit ship without per-step approval.
- `feedback_explain_tickets_in_full.md` honored — every "§" reference in this doc carries a one-sentence summary inline.
- Tailnet Lock setup work didn't surface anything new worth memory-fying (well-documented at https://tailscale.com/docs/features/tailnet-lock; user has the disablement secret captured).

---

## What this session deliberately did NOT do

- **Did not push** `eb-branch` to GitHub. Stop hook asked for push; standing memory policy `feedback_eb_branch_push_policy.md` overrides hook (user policy > tooling).
- **Did not deploy** to /Applications/Quip.app or the physical phone. Source-only ship for both §30/4 commits and all of Phase 3. `feedback_mac_rebuild_cost.md` (don't rebuild Mac for cosmetic-only iOS-driving log edits) makes the Mac side cheap to defer; the phone install is the real follow-up gating user verification.
- **Did not enable the Phase 3 swap toggle by default.** OFF until hardware verification across LAN/Tailscale/Cloudflare proves the policy doesn't flap or strand connections. Settings → Diagnostics → Latency → "Auto-pick fastest path" is the per-device opt-in.
- **Did not extend the §30/4 audit beyond WebSocketClient.** Most other repo `try?` sites are FileManager / Task.sleep / defer-close — legit silent. PinManifest disk decode (`WebSocketClient.swift:79,89`) is the one remaining audit hit; left alone since it's config-layer, not wire-layer.
- **Did not commit any docs/ wishlist edits this cont-8** — cont-7 already substantively rewrote §30, and the new latency hot-swap entry should wait until after hardware verify (don't file it as wishlist while it's actively-being-verified).
- **Did not auto-send the Tailnet Lock recap email** — Gmail MCP only has a `create_draft` tool; user reviews + sends from Gmail directly.

---

## Resume one-liner

> Continue Quip on `eb-branch` from `d102f2c`. Continuation 8 shipped 7 commits this session: §30/4 decode helper (`cc3bddc`) + encode-side type tagging (`6aca7d8`) + cont-7 handoff (`5caa1e7`) + Phase 3 spec (`06d133b`) + Phase 3/1 widening (`49160d5`) + Phase 3 spec revision (`bab9aad`) + Phase 3/2 per-URL bucketing (`f6d70cc`) + Phase 3/3 probe+policy+orchestration (`d102f2c`). Phase 2 (`abb89a9`) was user-driven mid-session. Combined test suite 621 → **658** (+37). NO DEPLOYMENT THIS SESSION — both /Applications/Quip.app and physical iPhone still on cont-6/7 builds. Phase 3 swap toggle defaults OFF; Settings → Diagnostics → Latency → "Auto-pick fastest path" is per-device opt-in once installed. Tailnet Lock enabled on user's tailnet (mac-studio23 + iphone182 trusted signers, disablement secret in password manager). Hardware punch list from cont-6/7 still pending. PR #29 still conflicting; paths B/C only. Tier-1 CRITs (#10/#11/#12/#13) still need user decisions.
