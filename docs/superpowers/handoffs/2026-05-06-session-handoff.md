# Session handoff — 2026-05-06 (full day)

Auto-written end of session per `feedback_recap_at_50pct.md`. Supersedes `2026-05-06-continuation-5-handoff.md` and the earlier `2026-05-06-session-handoff.md` (`d8b4c40`); this is the canonical record for everything that shipped today, including the post-cont-5 feature push. **Resume one-liner at the very bottom.**

---

## Today's commits (18 substantive + this handoff = 19, all pushed to `origin/eb-branch`)

### Tier-2 GH burn-down (5 issues closed)

| Hash | GH | Why |
|------|-----|-----|
| `3817e2b` | **#15** closed | Mac: CloudflareTunnel `Process` invocation audit. No shell-injection vector — both call sites use argv-array form, no shell layer. Refactored argv build into `static cloudflaredArguments(proxyPort:logPath:)` for testability. 7 regression tests. Audit doc at `docs/security/2026-05-06-cloudflared-process-audit.md`. |
| `32cb484` | **#14** closed | Mac: PIN UserDefaults→Keychain. New `PINStore` enum mirrors `APNsMetadataStore`. One-shot migration: legacy `QuipAuthPIN` → service `com.quip.mac.pin` / account `auth`. New PINs are 8 digits ≈27 bits (~100M combos); existing 6-digit PINs preserved through migration. 11 PINStoreTests. |
| `a9e2c5a` | **#19** closed | Mac+iOS+Shared: Mac→iOS app-level heartbeat. New `HeartbeatMessage`/`HeartbeatAckMessage` in `Shared/MessageProtocol.swift`. Mac: 15s `Timer` per server dispatches to authenticated direct-WS clients; logs to websocket.log if outstanding past 30s. iOS: incoming `heartbeat` echoes `heartbeat_ack(seq:)` via existing `send(_:)` Codable path. 4 MessageProtocolTests. |
| `babdc67` | **#20** closed | Mac+Shared: `arrange_windows.layout` String→`enum ArrangeLayout`. Codable rejects unknown rawValues at decode → loud failure + `ErrorMessage` broadcast. `LayoutMode.from(arrangeLayout:)` is the new total switch. Phone-side "grid" stays local. New tests cover unknown / grid / exhaustive enum / legacy-string overload. |
| `640b507` | **#24** closed | Mac: APNsMetadataStore + requireAuth lock test coverage (deferred from cont-4). 8 APNsMetadataStoreTests + 3 WebSocketServerRequireAuthTests including a 10k concurrent-read TSan canary. |

### Sim-QA bug fix

| Hash | Why |
|------|-----|
| `f779bd3` | iOS: `disconnect()` now also clears `lastError` + `connectingStartedAt`. Two-line fix for cont-3's sim-QA repro (top bar showed "Stalled 26s — resetting" simultaneously with "Enter tunnel URL" placeholder). 3 WebSocketClientDisconnectTests. **Install-verified** on QA sim at t=5s, t=40s, t=4min. |

### Handoffs

| Hash | Why |
|------|-----|
| `7481360` | Cont-5 handoff doc + branch-memory entry `feedback_no_filter_repo_main_conflict.md` (locks GH #16 + PR #29 path A as do-not-do per user policy). |
| `d8b4c40` | Earlier canonical session handoff "prep for /clear" — superseded by this doc but kept in history. |

### Connection + PTT visibility (G+H)

| Hash | Why |
|------|-----|
| `0001371` | iOS: **Story G** — BackendPickerSheet uses `manager.sessions[id].reachability` for every paired-backend row dot color + caption above URL ("Connected" / "Connecting…" / "Unreachable" / "PIN required" / "Off"). Pure classifier `BackendPickerSheet.classification(...)`. **Story H** — single-line PTT health banner above the main row. Hidden by default; surfaces mid-press disconnect / Whisper offline / warming up / downloading via priority-ordered `MainiOSView.classifyPTTBanner(...)`. 7 + 9 tests. |

### Codex CLI integration (I)

| Hash | Why |
|------|-----|
| `6186fee` | Mac+Shared: **Story I** — Codex CLI image-paste path. New `enum CLIKind { claude, codex, shell }` + optional `cliKind` field on `WindowState`. `TerminalStateDetector.classifyCLI(children:)` sniffs process names; codex match wins over claude/node (Codex is itself a Node app). New `KeystrokeInjector.pasteImage(at:to:terminalApp:iterm2SessionId:)` writes NSImage to NSPasteboard and Cmd+V's into iTerm2; image_upload routes by cliKind. 8 CLIKindClassifierTests. **Live-verified** classifier against running setup. |

### A11y + paste + scrollback + numbered prompts

| Hash | Why |
|------|-----|
| `13b69da` | iOS+docs: §B15 slot-row a11y sweep — customQuickButton / quickActionButton / promptQuickButton / promptsPickerButton + reset/disconnect/cancel-auth all gain `.accessibilityLabel/Hint/AddTraits(.isButton)`. Plus wishlist Done entries for cont-5 stories. |
| `4d1d21a` | iOS: §35 cross-app clipboard paste via keyboard long-press. UIPasteboard.string → SendTextMessage with 32 KiB ceiling; `clipText(_:maxBytes:)` trims by character so multi-byte glyphs never split into invalid UTF-8. 6 ClipTextTests. |
| `5fe7493` | Mac+iOS: §38 iTerm scrollback nav. Two chevron buttons in InlineTerminalContent header — tap = page; long-press = top/bottom. New `KeystrokeInjector.ScrollDirection` enum + `iterm2Scroll(_:to:iterm2SessionId:)` walks window→tab→session in AppleScript and sends Shift+PageUp/Down or Cmd+Home/End via System Events (iTerm2 default scrollback shortcuts). iTerm2-only; Terminal.app/Claude Desktop broadcast ErrorMessage. 5 Iterm2ScrollKeystrokeTests. |
| `551ca20` | iOS+Mac: §18 context-aware numbered-prompt chips. Pure detector `NumberedPromptDetector.detect(in:)` scans last 30 lines, requires `❯`/`>` cursor marker to disambiguate prompts from prose. Renders chip strip in InlineTerminalContent when ≥2 options found; tap fires `quick_action("select_<n>")` → Mac `sendText(digit, pressReturn: true)`. 12 detector tests. |

### Picker last-seen + top-bar enrichment + image upload recovery (J/K/L)

| Hash | Why |
|------|-----|
| `ab27a16` | iOS: **Story J** — picker shows "Last seen Xm/Xh/Xd ago" per backend. New optional `lastConnectedAt: Date?` on PairedBackend; auto-stamped on first layout_update of a connection cycle. Pure relative-time formatter with 60s/1h/1d/30d bands. Renders below the existing status·URL line; hidden when row is .connected. 8 new BackendPickerStatusTests. |
| `43466d3` | iOS: **Story K** — top-bar 4-state pill replacing binary green/yellow. New `enum TopBarStatus { unpaired, connected, connecting, authFailed, stalled }` with priority-ordered classifier. lastError keyword match: `auth`/`pin` → authFailed; `stalled`/`no pong`/`timed out` → stalled. 10 TopBarStatusTests. |
| `95f2e52` | iOS: **Story L** — image-upload categorized error chip + recovery affordance. Pure `ImageUploadFailure.classify(reason:)` enum (timeout / unknownWindow / invalidData / macDiskWrite / other). PendingImagePreviewStrip renders red chip + action capsule (Reset / Pick window / Try another / Retry); host wires the recovery flow per category. 11 ImageUploadFailureTests. |

### Diagnostic capture (§26)

| Hash | Why |
|------|-----|
| `8641ab7` | iOS: §26 shake-to-diagnose. `ShakeDetector` UIViewControllerRepresentable mounted as 0×0 background view; on shake presents `DiagnosticsSheet` with frozen iPhone snapshot (app version, connection flags, paired count, active backend, last 30 lifecycle events). Copy / Request Mac bundle buttons. Pure formatter `DiagnosticsSnapshotFormatter.format(_:now:)` keeps stable line order so triage scripts stay grep-friendly. 8 formatter tests. |

**18 substantive commits + 2 handoff commits** = **20 total today**. **49 commits ahead of main.** All pushed to `origin/eb-branch`.

## Test counts after today

| Suite | Start of day | End of day | Δ |
|-------|--------------|------------|---|
| QuipMac | 256 | **298** | +42 |
| QuipiOS | 195 | **275** | +80 |
| **Combined** | **451** | **573** | **+122** |

Both green. Run times: Mac ~21s, iOS ~7s.

## GitHub status

**Closed today (5):** #15 #14 #19 #20 #24

**Open (8):**
- **#26** META tracker
- **#17** HIGH HMAC over WS
- **#16** HIGH cloudflared filter-repo — **DO NOT TOUCH** per `feedback_no_filter_repo_main_conflict.md`
- **#13** CRIT hardened runtime + DEVELOPMENT_TEAM (TCC risk)
- **#12** CRIT App Sandbox (capability matrix decision)
- **#11** CRIT NSAllowsArbitraryLoads → allowlist (host list decision)
- **#10** CRIT TLS pinning (cert strategy decision)
- **#4** QuipLinux duplicate/close

## PR #29 status (carry-forward — unchanged)

Still **CONFLICTING** against main. Resolution paths still:
- ~~**A** force-push main with rewritten history~~ — **OFF** per user policy
- **B** cherry-pick today's 49 commits onto fresh branch off current main — loses the device-name redaction in main's history
- **C** squash-merge via GitHub UI — collapses everything into one commit on main, hash mismatch becomes irrelevant

User picks B or C when ready to merge.

## Wishlist active items remaining (8, was 12 at start of day)

| § | What | Notes |
|---|------|-------|
| §0c | PTT recognizer Settings picker + Whisper model-size selector | depends §0b; leverage §15 v2 sectioned-Settings |
| §4 | `/plan` button cross-platform parity | Watch + iPhone parity, needs design |
| §5 | `/plan` button v2 — optional auto-dictation | depends §0b/§0c |
| §24 | Crash recovery for QuipMac via launchd LaunchAgent | macOS LaunchAgent plist + relaunch policy |
| §30 | Reliability & UX hardening pass (5-thread backlog) | grouped follow-ups, broad |
| §56 | Voice macros — "ship it" → multi-step | open UX shape |
| §B15 | iPhone a11y — partial | main-row + slot-row + reset/disconnect already swept; remaining elements need paired sim to surface |
| §B17 | Trace `type=unknown (4 bytes)` frame | diagnostic shipped, **capture pending** — needs phone reconnect through post-462db63 Mac |

Items shipped today and flipped ✅ Done in `wishlist.md`: Bug-1 (sim QA), G picker reachability, H PTT banner, I Codex paste, §35 cross-app paste, §38 scrollback nav, §18 numbered chips, §26 shake-to-diagnose. Plus J/K/L (last-seen / top-bar / image-upload recovery — surfaced from user feedback during the session, no pre-existing wishlist entries).

## Branch memory updates this session

- **`feedback_no_filter_repo_main_conflict.md`** — locks GH #16 filter-repo + PR #29 path A (force-push main) as do-not-do until PR #29 is resolved. User explicit on 2026-05-06: "I don't wanna do anything that conflicts with Main."

## Install state (end of day)

| Surface | Build | Notes |
|---------|-------|-------|
| `/Applications/Quip.app` | Cont-4 build (CFBundleShortVersionString 1.5.1, mtime ~11:01 PT 2026-05-06) | **All Mac changes since cont-4 (#19 heartbeat, #14 PINStore, #20 enum, #15 audit, #24 tests, Story I Codex pasteImage, §18 select handler, §38 scrollback) need rebuild + re-sign + ditto for hardware verification** |
| iPhone 17 Pro Max physical | Cont-4 build (databaseSequenceNumber 9524) | Force-quit + reinstall needed to pick up: cont-4 Stories 3-6 + cont-5 (#15/#14/#19/#20/#24/Bug-1) + Story I + §B15 + §35 + §38 + §18 + §J + §K + §L + §26 |
| Quip QA sim (`D853A014-...`) | Cont-5 build of `f779bd3` | Bug #1 install-verified at t=5s/t=40s/t=4min ✅. Other today's features need a fresh build of latest tip for sim-side verification. |

## Hardware-verified ✅ vs install-only ⚠️

**Verified live this session (autonomous):**
- All 18 commits' logic — 122 new unit/integration tests across 13 new test files, all green.
- **Bug #1** install-verified on QA sim — cleanest empty-state behavior, no stale "Stalled Ns" leak.
- **Story I classifier** live-verified against running process tree on user's Mac (`node /usr/.../codex` → .codex, `claude` → .claude).

**Install-only — needs your eyes:**
- All cont-5 + post-cont-5 features need rebuild + reinstall + force-quit.
- Specific punch list compiled in the cont-4/cont-5 handoffs still applies; new items added today:
  - **Picker last-seen captions** (§J) — after a successful auth, picker should show "Connected" on the live row + "Last seen Xm ago" on inactive rows + "Never connected" on rows that never reached connected
  - **Top-bar status pill** (§K) — verify orange "Auth failed" appears with wrong PIN; red "Reconnecting…" appears after a watchdog stall; grey "Not paired" shows on a fresh-erased install
  - **Image-upload recovery** (§L) — wedge an upload (kill Mac WS during send, or upload to a window that's been closed) → chip should categorize correctly + Reset / Pick-window / Try-another button should work
  - **§26 shake-to-diagnose** — physically shake the iPhone → DiagnosticsSheet appears. Copy button writes snapshot to clipboard; Request Mac bundle button fires only when authenticated.
  - **§38 scrollback chevrons** — chevrons appear in the InlineTerminalContent header. Tap chevron-up = scroll one page; long-press = scroll to top.
  - **§18 numbered chips** — when Claude shows a numbered prompt, chips appear inline; tap to select.
  - **§35 keyboard long-press paste** — copy text from any iOS app, switch to Quip, long-press the keyboard button → text lands in selected window.
  - **Codex image upload** (Story I) — upload an image to a Codex iTerm2 window → image attaches via Cmd+V instead of typed path.

## Open threads (priority for resume)

1. **Rebuild Mac + reinstall iPhone**, run the punch list above. Lots of unverified ground from today.
2. **Capture §B17 trace** — `tail -F ~/Library/Logs/Quip/kokoro.log | grep §B17` after phone reconnects to the post-462db63 Mac. The first unknown-bytes log identifies the iOS sender.
3. **PR #29 resolution** — paths B (cherry-pick onto fresh branch) or C (squash-merge via UI) when ready to merge today's 49 commits to main. Path A is permanently off per memory.
4. **Tier-2 GH** when ready (need user decisions per issue): #11 ATS allowlist (host list) · #10 TLS pinning (cert strategy) · #12 App Sandbox (capability matrix) · #13 hardened runtime (TCC re-grant window) · #17 HMAC (design discussion).
5. **#16 cloudflared filter-repo** — **DO NOT WORK** per user policy memo.
6. **CI lint strategy** — 186k swiftformat + 300 cargo fmt debt unchanged from cont-3. (a) defer / (b) advisory `continue-on-error` / (c) mass-format commit.
7. **Wishlist remainders** — §0c §4 §5 §24 §30 §56 — all need user input on shape before autonomous ship.

## What this session deliberately did NOT do

- No filter-repo / force-push on `main` per user policy memo.
- No CI lint expansion — debt sizing was known, no formatter writes.
- No Tier-1 critical-security work (#10 #11 #12 #13) — each needs explicit user decisions.
- No #17 HMAC — high-effort multi-platform symmetric work.
- No #4 QuipLinux duplicate/close — separate stack.
- No physical-device install — Mac and iPhone are still on cont-4 builds.
- No §B17 trace capture — needs phone reconnect.

## Resume one-liner

> Continue Quip on `eb-branch` from `8641ab7`. Today's session shipped 18 substantive commits (5 GH-closing + Bug #1 fix + 12 features G/H/I/§B15/§35/§38/§18/§J/§K/§L/§26), all pushed to `origin/eb-branch`. **49 commits ahead of main.** Combined test suite 451→573 (+122 across 13 new test files), both schemes green. Branch memory `feedback_no_filter_repo_main_conflict.md` blocks GH #16 + PR #29 path A. **/Applications/Quip.app and physical iPhone are still on cont-4 builds** — every Mac+iOS feature shipped since needs rebuild + reinstall + force-quit before hardware verification. Punch list in this doc covers J/K/L/§26/§38/§18/§35/Story-I plus the carryover cont-4 Story 11 list. PR #29 still conflicting; resolve via B or C only. Open GH: 4 CRIT (#10/#11/#12/#13) need user decisions, #17 HMAC big lift, #16 do-not-touch, #26 META, #4 Linux. Wishlist active remainder: §0c §4 §5 §24 §30 §56 §B15-partial §B17. §B17 trace capture pending on phone reconnect. PTT/voice + Codex image flow + Codex window detection are all live in code; phone install will exercise them.
