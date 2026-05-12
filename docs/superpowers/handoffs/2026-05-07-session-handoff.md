# 2026-05-07 session handoff

Session ran from `6945e5e` (prior handoff) to `02f6457`. Caveman mode active throughout. Auto mode active for the second half. User on iPhone 17 Pro Max (`FA951BBB-D706-5FCF-9886-3E57560E9030`).

## Commits this session (newest first)

| Hash | Why |
|------|-----|
| `02f6457` | iOS §36 fix — InlineTerminalContent screenshot-refresh no longer yanks scroll to bottom; only re-pins when user was already within 40pt of floor (`onScrollGeometryChange`). |
| `b6e7668` | (parallel-thread) Handoff: 2026-05-06 cont-8 — §30/4 wrap + full Phase 3 latency load-balance. |
| `d102f2c` | (parallel-thread) Latency Phase 3 (3/3): probe + URLSwapPolicy + hot-swap orchestration. |
| `f6d70cc` | (parallel-thread) Latency Phase 3 (2/3): per-URL sample bucketing via serverURLHost. |
| `bab9aad` | (parallel-thread) Spec revision: latency load-balance targets URLs (same Mac), not Macs. |
| `49160d5` | (parallel-thread) Latency Phase 3 (1/2): tag samples with transport + network class. |
| `06d133b` | (parallel-thread) Spec: latency-driven load balancing across paired backends. |
| `abb89a9` | Latency Phase 2 — `SendTextAck` round-trip + iOS rolling samples + friendly `LatencyDiagnosticsSheet` (median per network/Mac/AppleScript, per-path buckets, sparkline). |
| `5caa1e7` | (parallel-thread) Handoff: 2026-05-06 cont-7 — §30/4 decode helper + encode-side type tagging. |
| `6aca7d8` | (parallel-thread) Mac+iOS §30/4 encode-side: name TYPE in encode-error logs. |
| `863ee28` | Mac latency Phase 1 — `~/Library/Logs/Quip/latency.log` written on every send_text with rid/path/cli/term/text_len/inject_ms/total_ms. |
| `cc3bddc` | (parallel-thread) iOS §30/4 — loud-drop helper for WebSocket decode errors. |
| `774d44d` | iOS Settings — Version row tap-to-copy ("Quip iOS 1.5.4 (1)" → clipboard, "Copied" pill 1.5s). |
| `1f5ea8e` | iOS PTT indicator surfaces *why* not green — inline `claude` / `shell` / `no mic` micro-tag next to mic icon. |
| `2e51160` | iOS Settings — About section with conventional Version row (CFBundleShortVersionString + CFBundleVersion). |
| `8b22b10` | iOS PTT readiness indicator — `mic.fill`/`mic`/`mic.slash` next to connection dot, classifies on (isAuthenticated, isAuthorized, selectedCLI == .codex). |

## Install state

- **Mac** `/Applications/Quip.app` — version string 1.5.2, binary mtime `May 6 22:03:26 2026`, contains all session commits through `abb89a9` (Phase 2 ack); does NOT contain `02f6457` (iOS-only) or any of the parallel-thread Phase 3 commits — would need a Mac rebuild to ship those server-side changes.
- **iOS iPhone 17 Pro Max** (`FA951BBB-D706-5FCF-9886-3E57560E9030`) — built + installed `02f6457` (§36 scroll fix is live on device).
- **iOS QA simulator** (`D853A014-E5D8-46F1-A81D-37860AA9DFA2`) — not installed this session.

## Hardware-verified vs install-only

| Commit | iPhone install | Hardware-verified |
|--------|---------------|-------------------|
| `8b22b10` PTT indicator | ✓ | partial — user "im on phone" + "ok" but didn't report icon color |
| `2e51160` Version display | ✓ | not confirmed |
| `1f5ea8e` PTT shortHint | ✓ | not confirmed |
| `774d44d` Tap-to-copy version | ✓ | not confirmed |
| `863ee28` Mac latency Phase 1 | Mac shipped | 1 sample logged (`pasteText` cli=codex, 75 chars, total_ms=450) |
| `abb89a9` Phase 2 ack + UI | ✓ both | not confirmed — phone was disconnecting after auth (session noise) |
| Parallel-thread Phase 3 commits | NOT shipped to /Applications | NOT installed on iOS device |
| `02f6457` §36 scroll fix | ✓ | not confirmed |

## Open threads

1. **iPhone connection instability.** Phone connects, sends auth signal, then disconnects ~30-50s later — happens on USB tether (`169.254.x`), LAN (`192.168.4.34`), and (per session start) Tailscale (`100.72.13.19`). Pattern matches iOS app suspending in background, but happened while user was actively interacting — root cause not pinned. Mac listener verified healthy, Bonjour broadcasting, LAN port reachable.
2. **Phase 3 commits not yet on /Applications.** Parallel-thread shipped `49160d5..d102f2c` for latency-driven URL load balancing. Mac binary is still `abb89a9`-era. Need a Mac rebuild + ditto to /Applications/Quip.app to activate.
3. **Latency baseline is 1 sample.** Phone needs to send ~10+ messages per path before regression detector tuning can begin. User asked me to "keep tabs" — wakeup loop is OFF after this handoff, restart with `Continue tracking ~/Library/Logs/Quip/latency.log` if desired.
4. **Auto-agent dispatch (Phase 3 user-facing).** User confirmed they want auto-agent on regression. Phase 3 from parallel thread does URL load-balance, NOT agent dispatch. The "spawn `claude --print` on regression" launchd watcher hasn't been built. Smart-signal design discussed: only fire when `processing_ms` outliers AND `net_rtt` is at-or-below its own median (rules out weak Wi-Fi). Suppress on `path.isExpensive` / `path.isConstrained`.
5. **§34 mac_permissions** — verified pipeline intact (Mac broadcast on auth/timer/wake → iOS decode → manager fanout → state binding); marked as not-an-active-bug.
6. **Screen Recording TCC** — Mac was rebuilt + ditto'd this session; cdhash changes can silently revoke this grant. User has not confirmed terminal screenshots are still flowing as pixels (vs the monospace fallback).
7. **iOS app version still says 1.5.4 — but `iOSCFBundleShortVersionString` was bumped to 1.5.4 prior session; Mac still 1.5.2 in source. Mismatch is fine for now, version display feature works.**

## Backlog snapshot

Wishlist file `docs/superpowers/wishlist.md` (801 lines). Open items asked-about today:

- §34 mac_permissions never received — **resolved** (pipeline intact; was stale-build artifact).
- §36 scroll cap in InlineTerminalContent — **fixed** in `02f6457`, hardware-verification pending.

Backlog highlights still open: §0/0b/0c PTT reliability, §1–§7 `/plan` shortcut, §29 launch iTerm from iPhone, §35 cross-app paste, §38 scrollback nav, §39/§40 auto-arrange + drag-to-move, §43 custom quick-buttons editor, §47 HEIC encode, §B4 prompts pasting wrong window, §41 volume-KVO clobber, §B9 PTT silent-fail no window. See wishlist for full list.

## Resume command for fresh session

> "Resume Quip eb-branch session. Latest commit `02f6457` (iOS §36 scroll fix). Mac `/Applications/Quip.app` is at `abb89a9`-era binary — Phase 3 latency commits (49160d5..d102f2c) need a Mac rebuild + ditto to ship. iPhone 17 Pro Max has `02f6457` installed. Open threads: phone disconnect-after-auth pattern, latency baseline at 1 sample, auto-agent dispatch script not yet built, Screen Recording TCC unverified post-rebuild. Read this handoff for the full state."

## Not pushed

eb-branch is local-dev only per `feedback_eb_branch_push_policy.md` — handoff committed locally, NOT pushed to GitHub. User must explicitly say "push" if they want it remote.
