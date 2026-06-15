# Session handoff — 2026-06-15

Branch `eb-branch`, **6 commits ahead of origin, UNPUSHED** (held per eb-branch push policy — awaiting explicit "push").

## What this session did
Started as "PTT doesn't recognize Codex/Grok, unexplained for months." Ended spanning three fixes + a live
production incident (Mac app crash). Root causes were all distinct from how they first looked.

## Commits (newest first — hash + why)
- `579c56c` docs: log prompt-save crash fix + open WS connection follow-ups
- `997a196` **Stop prompt-save from crashing the whole Mac app** — `PromptLibrary.put` switched to ObjC
  `FileManager.createFile` (can't trap) instead of swift-foundation `String.write(atomically:)` which
  SIGTRAP'd and killed the app (2026-06-14 18:14), dropping all phone connections. + regression test.
- `4cc64ed` docs: mark Grok/Codex PTT acceptance passed + latency follow-up
- `317530f` **Gate PTT just-in-time reclassify to `.shell` cache only** — the unconditional `refreshCLIKind`
  (`ps -ax`) from `5151384` regressed common Claude PTT ~75ms→~350ms; gate restored snappy on positive caches.
- `d83c978` docs: log Grok/Codex PTT fix + open acceptance test
- `5151384` **Fix PTT into Grok/Codex panes + add classification telemetry** — send_text now JIT-reclassifies
  when cache is `.shell` (was routing voice down the dropped sendText path); new `classify.log`; PTTReadiness
  generalized Codex→Codex|Grok; `PTTReadinessTests`.

## Install state
- **Mac**: `/Applications/Quip.app` **v1.5.5 (build 1)**, running pid 49627, listening on 8765, codesign seal
  valid (stable cert `813F0602…`, ditto install, orphan dylibs pruned). Contains ALL session commits.
- **iOS**: build from `5151384` installed on **iPhone 17 Pro Max** (`FA951BBB-D706-5FCF-9886-3E57560E9030`)
  yesterday. NOT rebuilt since — so the iOS side has the PTTReadiness grok badge fix; no iOS changes after.

## Verified vs install-only matrix
| Change | Status |
|---|---|
| Grok/Codex PTT lands in pane | ✅ **hardware-verified** (latency.log 17:09, `cli=grok/codex success=1` via pasteText) |
| classify.log telemetry writes live | ✅ **hardware-verified** (lines captured) |
| Latency gate restores snappy Claude PTT | ✅ **verified by data** (overhead total−inject 64–133ms → 2–3ms) |
| PTTReadiness shows Grok as "Ready for voice" | ⚠️ unit-tested only — needs visual confirm after phone reconnect |
| Prompt-save no longer crashes Mac | ⚠️ unit-tested + installed — needs a real save on v1.5.5 to confirm on hardware |
| WebSocket connection stability | ❌ NOT fixed — open (see below) |

## Open threads
1. **Reconnect the phone** (foreground app on same wifi → X/reconnect or relaunch). Since 17:10 it held no
   connection. Then confirm: (a) Grok pane shows green "Ready for voice"; (b) saving a prompt doesn't crash.
2. **Tailscale WS path never reaches `ready`** — opens every ~60s, stuck at `preparing`, resets. WiFi works.
3. **`pasteText` blocks Mac main thread ~2.5s/press** — 3 grok presses ≈ 7.5s may trip the phone's 25s stall
   watchdog → reset (would feel grok/codex-specific). Hypothesis, unconfirmed.
4. **Push** — 6 commits await explicit confirmation.

## Update — Codex/Grok PTT speed fix (commit `640457c`, installed v1.5.5, UNVERIFIED)
Root-caused the 2.5–3.1s grok/codex inject: NSAppleScript itself is only ~500ms (proven via osascript +
swift harness timing), but `pasteText` ran on the **contended main actor** — the Apple Event reply-wait is
serviced on the run loop, so a busy main loop inflated 0.5s→2.5s AND blocked main (starving WS keepalive →
likely a cause of the connection resets). Fix: `pasteText`/`executeAppleScript` made `nonisolated`; send_text
runs the pasteText route on a background queue, hops to main only for self-heal/log/broadcast (line-660
`readContent` precedent). sendText (Claude) unchanged. **Pending:** press grok/codex PTT and confirm
`latency.log` `inject_ms` drops ~2500 → ~500–800ms (idle phone all session, never pressed on this build).

## Resume command for a fresh session
"On Quip eb-branch (6 unpushed commits, Mac v1.5.5 installed): confirm on the reconnected iPhone 17 Pro Max
that the Grok mic badge is green and saving a prompt no longer crashes the Mac, then investigate the
Tailscale WebSocket path that never reaches `ready` (see docs/superpowers/handoffs/2026-06-15-session-handoff.md)."
