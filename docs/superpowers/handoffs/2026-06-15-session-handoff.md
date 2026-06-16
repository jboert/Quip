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

## Update 2 — parallel-agent tracks + follow-on fixes (commits `de9936f`, `85e0af2`)
- **Serial paste queue (`de9936f`, Mac v1.5.5 installed):** code review of `640457c` found the off-main
  pasteText used the CONCURRENT global queue → rapid presses could race the shared NSPasteboard
  snapshot/restore + interleave keystrokes. Fixed: dedicated SERIAL queue `com.quip.mac.paste-inject`
  (still off-main = fast, but ordered + race-free).
- **iOS adaptive connect timeout (`85e0af2`, installed on iPhone 17 Pro Max):** unreachable primary URL
  stalled the full 8s before failover. Now 4s while a fallback URL remains, 8s on the last URL. Cuts the
  dead-Tailscale-primary stall in half. UNVERIFIED on a bad network.
- **Tailscale never-`ready` (Track A — PARKED, do NOT rush):** root cause is the Mac WS listener binds
  IPv4-only (`WebSocketServer.swift:288`) but the Tailscale direct peer path is IPv6. The obvious fix
  (parallel v4+v6 listeners) is DOCUMENTED TO FAIL in `start()` (lines 198–212): EADDRINUSE, because
  NWListener forces `IPV6_V6ONLY` with no knob. Real fix = raw POSIX socket with `IPV6_V6ONLY=0` wrapped
  into Network.framework — a hard, low-level change to the PROVEN WS server. Symptom already softened by
  the adaptive timeout; wifi carries everything. Tackle in a focused session, not under context pressure.
- **Remaining safe iOS micro-wins (not done):** defer notification-category registration + permission
  prompts off the first frame (`QuipApp.swift:267,460`, few-hundred-ms cold start); eager-auth RTT
  (`WebSocketClient.swift:888–922` — has a `requireAuth=false` footgun, do server-side).

**Commits now ahead of origin: 13** (still UNPUSHED — awaiting explicit "push").

## Update 3 — 2026-06-15 PM: PUSHED + prompt-save proven + flap root-caused
- **PUSHED.** `git push origin eb-branch` → `1286251..03ab20d` (authorized via phone PTT "u can push" in
  audit.log + in-chat "Proceed"). Branch now **0 ahead, in sync with origin/eb-branch.** No longer unpushed.
- **Prompt-save mobile→Mac is PROVEN working.** Phone screenshotted the red "Connect to the Mac before
  saving prompts" at 8:59 PM — but `code-review.txt` (514 B) is on the Mac with mtime **Jun 15 20:59**, clean,
  no `.sb-` orphan. The save LANDED; the createFile + @Sendable-watcher fixes (997a196, 03ab20d) hold in
  production. The red error was a **transient connection flap**, not a pipeline failure.
- **Flap root-caused (NEW evidence).** `netstat -an | grep 8765` showed **TWO** ESTABLISHED sockets to one
  Mac — LAN `192.168.4.34` + Tailscale `100.72.13.19` — flapping independently. `connect(toURLs:)` is
  sequential (one task), so two live sockets ⇒ Mac paired as **two backends** / BCM spawns two clients. Each
  cycles `ready (pending auth)` → POSIX 57 ENOTCONN ~7s later. `!isConnecting` guard (950c3fd) dampens, does
  not eliminate. `onSave` returns false when `send()` fires mid-flap → the scary error. Saved to memory
  `project_ws_dual_backend_flap`. **Real fix = dedupe to ONE backend per Mac (LAN+TS as fallback within one
  client) and/or queue+retry the save through a flap. Needs iOS rebuild (disruptive). PARKED — don't crack
  under context pressure.**

## Resume command for a fresh session
"On Quip eb-branch (in sync with origin, Mac v1.5.5 installed): prompt-save mobile→Mac is proven working and
all session work is pushed. The open issue is the dual-backend connection flap (phone holds two ESTABLISHED
sockets LAN+Tailscale to one Mac, each flapping → save intermittently shows 'Connect to the Mac'). See
memory `project_ws_dual_backend_flap` + this handoff Update 3. Fix needs an iOS rebuild; confirm timing with
the user first since it disconnects the phone mid-use."
