# Session handoff — 2026-05-06 (continuation 6 + full day cumulative)

Auto-written end of session per `feedback_recap_at_50pct.md`. **Supersedes the earlier 2026-05-06 handoff (`a103604`)** — that doc covered the first 18 commits of the day; this one adds the 6 commits from continuation 6 (§24 + §30/1 + §30/2 + Codex pasteText + iOS 1.5.4 + send_text NSLog) and re-states the cumulative state. **Resume one-liner at the very bottom.**

---

## Continuation 6 commits (this session, 6 substantive)

| Hash | Why |
|------|-----|
| `5cbd1f4` | Mac: **§24 crash-recovery LaunchAgent (opt-in).** New `CrashRecoveryAgent` enum writes `~/Library/LaunchAgents/com.quip.QuipMac.crash-recovery.plist` and bootstraps via `launchctl bootstrap gui/$UID`. KeepAlive gated on `Crashed=true` + `SuccessfulExit=false` so Cmd+Q never triggers relaunch loop. Settings → General → Reliability has the toggle. 10 CrashRecoveryAgentTests. |
| `5b2a6a8` | Mac+iOS: **§30 thread #1 — loud-drop logging across 5 services.** Extends the `8517835` push-service seed pattern. Failure paths now log enough context to spot the cause: WatchSyncService (encode + sendMessage + applicationContext), PromptLibrary (directory listing + per-file decode), CloudflareTunnel (pgrep launch), PushNotificationService (devices/preferences encode), MessageDedupeTable (cap eviction means phone is flooding). |
| `9f382ef` | iOS: **§30 thread #2 — DisconnectReason structured signal.** New `DisconnectReason` enum: userInitiated / timedOut / stalled(seconds) / authFailed(message?) / networkError(String) / serverClosed / unknown. Each disconnect site sets typed reason BEFORE clearing isConnected. `WebSocketClient.lastDisconnectReason` is the new slot; lastError stays for back-compat (computed from reason.label). New `TopBarStatus.classify(reason:)` overload prefers structured signal over keyword-matching. DiagnosticsSheet shows `lastDisconnectReason: <tag>`. 29 new tests. |
| `0f578a1` | Mac: **Codex CLI text-paste path (Story I follow-up); 1.5.2.** PTT transcripts to Codex windows silently vanished — sendText's `write text` writes raw bytes to PTY stdin, which Codex's composer ignores. Mirrors Story I image path: new `KeystrokeInjector.pasteText(_:to:pressReturn:terminalApp:iterm2SessionId:)` writes to NSPasteboard + Cmd+V via System Events + optional Enter. send_text handler branches by cliKind: `.codex` + `.iterm2` → pasteText; everything else preserves legacy. Pure `pasteTextScript(...)` exposed nonisolated for tests. 9 PasteTextScriptTests. |
| `1b5ab95` | iOS: **bump CFBundleShortVersionString 1.5.3 → 1.5.4.** Distinguishes the post-§30 build from the prior 1.5.3 install on the phone. |
| `e0c663c` | Mac: **NSLog send_text routing decision (cliKind branch observability).** `send_text routing: pasteText (cliKind=codex, ...)` vs `sendText (cliKind=<x>, ...)` — log line lets future "Codex PTT not pasting" debugging settle in <5s with `log stream --predicate 'process == "Quip" AND eventMessage CONTAINS "send_text routing"' --style compact`. Caught the "codex wasn't running in pane" footgun on first hardware test. |

**6 substantive commits** + this handoff = **7 total this continuation**. Total since main: **~50 commits ahead** of main.

## Cumulative day commits (24 total since main, full-day timeline)

Chronological — earlier commits described in the superseded handoff `a103604`:

`f779bd3` Bug-1 sim QA · `3817e2b` GH #15 · `32cb484` GH #14 · `babdc67` GH #20 · `a9e2c5a` GH #19 · `640b507` GH #24 · `0001371` Story G+H · `7481360` cont-5 handoff · `d8b4c40` cont-5b handoff · `6186fee` Story I (Codex image) · `13b69da` §B15 a11y · `4d1d21a` §35 cross-app paste · `5fe7493` §38 scrollback · `551ca20` §18 numbered chips · `ab27a16` §J last-seen · `43626ef` §K top-bar pill · `95f2e52` §L image-upload chip · `8641ab7` §26 shake · `a103604` mid-day handoff · **`5cbd1f4` §24 launchd** · **`5b2a6a8` §30/1 loud-drop** · **`9f382ef` §30/2 DisconnectReason** · **`0f578a1` Codex pasteText 1.5.2** · **`1b5ab95` iOS 1.5.4 bump** · **`e0c663c` send_text NSLog**

## Test counts

| Suite | Start of day | End of day | Δ |
|-------|--------------|------------|---|
| QuipMac | 256 | **317** | +61 |
| QuipiOS | 195 | **304** | +109 |
| **Combined** | **451** | **621** | **+170** |

Both green. Mac 22s, iOS 7.5s.

## Install state (end of session)

| Surface | Build | mtime | Notes |
|---------|-------|-------|-------|
| `/Applications/Quip.app` | **1.5.2** | 2026-05-06 16:30:04 PT | All Mac changes today (§24 launchd + §30/1 loud-drop + Story I Codex image + Codex pasteText + send_text NSLog). Stable cert + entitlements verified live. |
| iPhone 17 Pro Max physical | **1.5.4** | databaseSequenceNumber 9540 | All today's iOS commits — DisconnectReason, J/K/L, §26 shake, §35/§38/§18, §B15. **Force-quit needed before testing.** |
| QA sim D853A014 | cont-5 build of `f779bd3` | — | Bug #1 install-verified only. Other features need fresh QA build. |

## Hardware-verified ✅ vs install-only ⚠️

**Verified live this session:**
- ✅ Codex PTT pasteText path — 1st test failed (codex wasn't running, classifier returned .shell); after launching codex → 2nd test PTT text appeared and submitted in Codex composer.
- ✅ Stable cert + entitlements survived ditto — `codesign -d --entitlements` shows apple-events / network.client / network.server intact.

**Untested on hardware (today's phone-side features still need force-quit + retest):**
- ⚠️ §24 LaunchAgent — toggle + force-crash test pending
- ⚠️ §30/2 DisconnectReason — wrong-PIN / kill-Mac scenarios pending
- ⚠️ §26 shake-to-diagnose — phone shake → DiagnosticsSheet (now also shows `lastDisconnectReason: <tag>`)
- ⚠️ §J last-seen captions / §K 4-state pill / §L image-upload chip
- ⚠️ §35 cross-app paste · §38 iTerm scrollback · §18 numbered chips
- ⚠️ §B15 a11y sweep verification

## §30 status update

**Threads #1 + #2 shipped this session.** §30 wishlist entry should reflect:
- Thread #1 (loud-drop logging): partial → **mostly shipped** (5 service sites added; can extend further as new sites surface).
- Thread #2 (status-pill honesty): partial → **shipped** (DisconnectReason structured + §K consumes it).
- Thread #3 (lifecycle invariants): **untouched.**
- Thread #4 (try?/silent guard repo audit): **untouched.**
- Thread #5 (notification triage view): **untouched.**

§30 is now half-eaten. Could re-classify as meta tracker + spawn fresh wishlist entries for #3/#4/#5.

## Wishlist active items remaining (post-session)

| § | What | Notes |
|---|------|-------|
| §0c | PTT recognizer Settings picker + Whisper model-size | depends §0b acceptance + needs §15 v2 sectioned-Settings |
| ~~§4~~ | ~~`/plan` cross-platform parity~~ | **DROPPED — Jakob's lane** (memory: `feedback_skip_linux_android.md`) |
| §5 | `/plan` v2 auto-dictation | needs UX shape decision |
| ~~§24~~ | ~~Crash recovery LaunchAgent~~ | **✅ Done this session (`5cbd1f4`)** |
| §30 | Reliability hardening pass | half-eaten; threads #1/#2 shipped, #3/#4/#5 still wishlist |
| §56 | Voice macros | open UX shape |
| §B15 | a11y remaining | quick verify; re-run audit script |
| §B17 | unknown-frame trace | diagnostic in code; capture pending phone reconnect to post-462db63 Mac |

## Open threads (priority for resume)

1. **Hardware verification punch list** — every phone-side feature shipped today still needs force-quit + retest on physical iPhone (1.5.4). §24 LaunchAgent + §30/2 DisconnectReason + §26/§J/§K/§L most critical.
2. **§B17 trace capture** — `tail -F ~/Library/Logs/Quip/kokoro.log | grep §B17` after phone reconnects to the post-462db63 Mac (now at 1.5.2 with diagnostic in code).
3. **PR #29 resolution** — paths B (cherry-pick onto fresh branch) or C (squash-merge via UI) when ready. Path A locked off per `feedback_no_filter_repo_main_conflict.md`.
4. **Tier-2 GH** — #11 ATS allowlist · #10 TLS pinning · #12 App Sandbox · #13 hardened runtime · #17 HMAC. All need user decisions.
5. **GH #16 filter-repo** — locked off per memory.
6. **§30 follow-through** — threads #3 (lifecycle invariants) / #4 (silent guard audit) / #5 (notification triage view) if doing more reliability work.
7. **CI lint debt** — 186k swiftformat + 300 cargo fmt unchanged. Still (a) defer / (b) advisory continue-on-error / (c) mass-format commit.

## Branch memory updates this session

- **`feedback_skip_linux_android.md`** — Jakob owns QuipLinux/QuipAndroid; never propose §4 parity, GH #4, or any cross-platform mirror to non-Apple clients.
- **`project_codex_classifier_runtime.md`** — Codex CLI must be RUNNING in the iTerm2 pane for `classifyCLI` to return `.codex`; idle pane = `.shell` and pasteText/pasteImage branches never fire. Verified live 2026-05-06.

## What this session deliberately did NOT do

- No filter-repo / force-push on `main` per user policy memo.
- No CI lint expansion.
- No Tier-1 critical-security work (#10 #11 #12 #13).
- No #17 HMAC.
- No #4 QuipLinux duplicate/close (Jakob's lane per new memory).
- No §B17 trace capture — needs phone reconnect to 1.5.2 Mac.

## Resume one-liner

> Continue Quip on `eb-branch` from `e0c663c`. Continuation 6 shipped 6 substantive commits (§24 LaunchAgent + §30/1 loud-drop × 5 services + §30/2 DisconnectReason + Codex pasteText 1.5.2 + iOS 1.5.4 + send_text routing NSLog). Total day **~50 commits ahead of main, all pushed to `origin/eb-branch`**. Combined test suite 451→**621** (+170). `/Applications/Quip.app` is on **1.5.2** (mtime 16:30:04, stable cert + entitlements verified). iPhone 17 Pro Max is on **1.5.4** (databaseSequenceNumber 9540). Codex PTT text-paste **verified live** ✅ (after launching codex in pane). Branch memories updated: `feedback_skip_linux_android.md` blocks Linux/Android work, `project_codex_classifier_runtime.md` documents the codex-must-be-running gotcha. Hardware punch list for phone-side features remains untested. PR #29 still conflicting; paths B/C only. §30 threads #3/#4/#5 still wishlist. Tier-1 CRITs (#10/#11/#12/#13) still need user decisions.
