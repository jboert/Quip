# Swallowed-error sweep — combined audit (QuipMac + QuipiOS)

**Date:** 2026-07-13 · **Branch:** `eb-branch` · **Scope:** QuipMac + QuipiOS.
QuipLinux / QuipAndroid / Shared not swept.

**Enumeration is mechanical and complete. Nothing was sampled. Nothing is
truncated.** Every enumerated line on both peers is listed below under exactly
one bucket. If you are looking for a site and it is not here, it was not in the
grep set — and the grep set is stated verbatim in *Method* so you can re-run it.

## Why this document exists

The sweep ran in two halves. The **QuipiOS** half produced a complete
classification (`.superpowers/sdd/task-6b-report.md`, reproduced in full below).
The **QuipMac** half was interrupted: it committed its fixes
(`ad979df`, `ceeb999`, `88370db`, `b8279bd`, `a7752f8`) but **never wrote its
accounting** — so there was no record of which Mac sites were examined, which
were judged benign, or whether coverage was complete. "We covered everything" was
an assertion nobody could check. This document supplies the missing QuipMac
accounting and folds both halves into one auditable record.

---

## Headline totals

| | QuipMac | QuipiOS | Both |
|---|---|---|---|
| Raw grep lines | 215 | 329 | 544 |
| **Distinct sites classified** | **212** | **313** | **525** |
| — grep artifacts / doc comments | 5 | 7 (+2 dup, +7 continuation) | 12 |
| — **BENIGN control flow** | **185** | **269** | **454** |
| — **REAL swallow shape, failure IS surfaced** | **12** | (folded into the two rows below) | — |
| — **REAL swallow, SILENT (still open)** | **10** | **8** | **18** |
| **REAL swallows found by the sweep** | **27** | **44** | **71** |
| — **fixed** | **17** | **36** | **53** |
| — **still open** | **10** | **8** | **18** |

Arithmetic, QuipMac: 212 = 5 artifacts + 185 benign + 12 real-but-reported + 10 real-and-silent. ✅
Arithmetic, QuipiOS: 313 = 269 benign + 44 real (36 fixed + 8 not fixed). ✅
Real swallows: 27 Mac (17 fixed + 10 open) + 44 iOS (36 fixed + 8 open) = **71 total, 53 fixed, 18 open**. ✅

> **Why QuipMac's "27 real" is larger than the 22 real-shaped sites in its
> current-tree grep:** the fix commits converted 15 of the 17 fixed swallows from
> `try?` / bare-`guard` into `do/catch`, so those sites **no longer match the
> grep at all**. A present-tense grep of the tree *under-reports* the sweep's own
> work. Both views are given below and they reconcile: 17 fixed = 15 no longer
> grep-visible + 2 still grep-visible but now loud.

---

## Method

Sites were enumerated mechanically, not by reading for suspicion:

```sh
{ grep -rn "try?"              --include="*.swift" QuipMac | grep -v "/Tests/"
  grep -rn "else { return }"   --include="*.swift" QuipMac | grep -v "/Tests/"
  grep -rn "else { return nil }" --include="*.swift" QuipMac | grep -v "/Tests/"
} | sort > /tmp/quip-mac-swallow-sites.txt      # 215 lines → 212 distinct sites
```

(The QuipiOS half used the identical three patterns against `QuipiOS`.)

215 raw lines collapse to 212 distinct sites: 3 source lines match two patterns
at once (a `guard let x = try? … else { return }` is hit by both the `try?` grep
and the `else { return }` grep).

A **baseline** enumeration was also taken at `ad979df~1` (the commit before the
first Mac fix) — 218 sites — so that swallows *fixed* by the sweep, which the
fixes removed from the grep's reach, could still be counted.

### The classification rule

Every site lands in exactly one bucket:

- **REAL SWALLOW** — an error value or failure path is discarded: a `try?` that
  drops a thrown error the caller could have acted on; a `guard`/`else` that
  returns on an **unexpected** condition (failed decode, failed encode, failed
  write, missing window, dead socket, denied TCC grant) **without reporting it
  anywhere**. The test is: *if this fires in the field, is there any trace?*
- **BENIGN CONTROL FLOW** — an optional unwrap where `nil` is an ordinary
  expected value; `guard let self else { return }` teardown; an early return on
  an empty collection; a re-entrancy/idempotence guard; a parser returning `nil`
  for "doesn't match this pattern"; a cache miss; best-effort cleanup in `defer`
  (`try? handle.close()`, `try? removeItem` on a temp file); `try? Task.sleep`
  (cancellation is not an error).
- **GREP ARTIFACT** — the pattern matched a substring, not code. `PromptEntry?`
  literally contains the characters `try?`. Doc comments that *describe* a
  swallow also match.

**Most sites are benign, and that is the point.** Blanket-logging control flow
would bury the real signals under new noise — the exact disease this sweep is
curing. The swallow count was not inflated to look thorough.

---

# PART 1 — QuipMac (the missing accounting)

## 1.1 Buckets

| Bucket | Count |
|---|---|
| BENIGN control flow | 185 |
| REAL swallow shape, failure IS surfaced | 12 |
| REAL swallow, SILENT — **still open** | 10 |
| Grep artifacts / doc comments | 5 |
| **Total distinct sites** | **212** |

Plus **15 real swallows fixed by the sweep that no longer appear in the grep**
(converted to `do/catch`, or were `catch` blocks the grep never saw). Full list
in §1.3.

## 1.2 REAL swallows — fixed (17)

| # | Site (pre-fix) | Commit | What was being swallowed |
|---|---|---|---|
| 1 | `PushNotificationService` `loadDevices` `try? decode([RegisteredPushDevice])` | `ad979df` | Corrupt blob → `devices` empty → **every** `notify*` path takes its `guard !devices.isEmpty else { return }` exit. Push goes 100% silent, nothing says why. |
| 2 | `PushNotificationService` `loadPreferences` `try? decode([String: DevicePushPreferences])` | `ad979df` | Corrupt/drifted blob → silent fallback to `.defaults` (`paused=false`). **"Pause All" stops working and push fires anyway.** |
| 3 | `QuipMacApp:363` `guard let type = MessageCoder.messageType(from: data) else { return }` | `ceeb999` (+ per-connection sink in `a7752f8`) | Malformed inbound frame dropped on the floor — a phone-side send vanishes into thin air. |
| 4 | `QuipMacApp` `guard let msg = try? decode(AudioChunkMessage) else { break }` | `ceeb999` | Dropped dictation audio → short/empty transcript → "PTT does nothing", with the blame landing on the phone. |
| 5 | `CloudflareTunnel` `cloudflared` launch `catch` | `ceeb999` | Missing binary / bad perms / exec denied → `isRunning = false` and **nothing logged**. Tunnel sits off, no URL, no reason recorded. |
| 6 | `CloudflareTunnel:668` `if let responseData = try? encode(AuthResultMessage)` | `ceeb999` | Encode failure → **no auth reply sent at all** → phone hangs on "Connecting…" forever, no trace on either peer. |
| 7 | `QuipMacApp` `let roots = (try? decode([String])) ?? []` | `88370db` | Configured project roots silently vanish from the phone's spawn picker. |
| 8 | `QuipMacApp` `if let children = try? fm.contentsOfDirectory(atPath: root)` | `88370db` | A user-configured root that moved / was deleted / is unreadable silently disappears from the broadcast. |
| 9 | `QuipMacApp` `if let encoded = try? encode(msg.preferences)` | `88370db` | Phone believes its settings are backed up; nothing is stored; the loss surfaces later as a **wiped config after reinstall**. |
| 10 | `QuipMacApp` `let decoded = try? decode(PreferencesSnapshot.self, from: blob)` | `88370db` | "No backup exists" (ordinary) and "a backup exists but won't decode" (schema drift) collapsed into one branch — and one **lie**: the old code logged "no backup for device" for both, then handed the phone defaults. |
| 11 | `SettingsView` `try? decode([SavedLayoutPreset])` | `88370db` | Saved layout presets silently reset. |
| 12 | `SettingsView` `try? decode([String])` (project directories) | `88370db` | Configured directories silently reset. |
| 13 | `SettingsView` `try? encode(directories)` | `88370db` | Directory edit silently not persisted. |
| 14 | `SettingsView` `try? encode(presets)` | `88370db` | Preset save silently not persisted. |
| 15 | `KeystrokeInjector` `screencapture` launch `catch` | `b8279bd` | Capture process wouldn't launch → bare `nil`. |
| 16 | `KeystrokeInjector` `guard process.terminationStatus == 0 else { return nil }` | `b8279bd` | Non-zero exit → bare `nil`. |
| 17 | `KeystrokeInjector` `guard let data = contents(atPath: tmpPath) else { return nil }` | `b8279bd` | **Exit 0 but no file on disk — the classic silent-TCC-denial shape.** A window that wouldn't capture was indistinguishable from one with nothing to show, and the overwhelmingly likely cause (Screen Recording grant lost on a Mac rebuild) left no trace anywhere. |

`a7752f8` fixed **no additional swallows**. It is a noise-control commit: it
introduces `LogTransitionPolicy` so the repeating-path logs added by #3, #4 and
#15–17 report **state transitions** (first failure, change of reason, recovery)
rather than firing on a per-frame / per-poll cadence. Without it, the fixes above
would have spammed the very logs they were meant to make readable. It also adds
the per-connection malformed-frame sink in `WebSocketServer.receiveMessage` that
backs site #3.

2 of these 17 (#3 `QuipMacApp:363`, #6 `CloudflareTunnel:668`) are still matched
by the grep today — they appear in §1.6 as "real shape, now reported". The other
15 became `do/catch` and left the grep's reach entirely.

## 1.3 REAL swallows — STILL OPEN (10)

Not fixed. Listed with a one-line risk note each. **No code was written for these**
— a follow-up decides what to fix.

| Site | Risk if it fires |
|---|---|
| `QuipMac/Services/WindowManager.swift:352` | `focusWindow` aborts on a failed `AXUIElementCopyAttributeValue` with **zero output**, while the near-identical guard in `moveWindow:418` prints "Failed to get AX windows for pid … Check Accessibility permission." **A revoked Accessibility grant makes focus silently do nothing** — and this repo re-loses that grant on every Mac rebuild. **Highest-value open item.** |
| `QuipMac/Services/AuditLogger.swift:58` | `guard let handle = try? FileHandle(forWritingTo: url) else { return }` — a **security-relevant audit entry is dropped** with no fallback and no trace. `QuipLog.swift:55` at least retries with `createFile`; this doesn't. An audit log that silently stops auditing is worse than none. |
| `QuipMac/Services/PromptLibrary.swift:344` | `guard fd >= 0 else { return }` — a failed `open(O_EVTONLY)` leaves the prompts FS-watcher **silently un-started**. Prompt edits stop broadcasting to paired phones with no breadcrumb; the feature looks dead. |
| `QuipMac/Services/PromptLibrary.swift:81` | `put()` returns `nil` on a rejected id, but both call sites (`SettingsView:783`, `:788`) do `_ = library.put(...)` and dismiss the sheet — **a rejected save looks exactly like a successful one.** |
| `QuipMac/Services/SwrmProjectStore.swift:46` | `try? decode([String])` — a corrupt blob **silently forgets every configured swrm project root**. The paired writer `persist()` logs its errors; the reader doesn't. |
| `QuipMac/Services/SwrmEventTailer.swift:276` | `try? decode(SwrmCursor)` — a corrupt cursor silently resets to `.zero`, causing a **full event replay**. `save()` logs; `load()` doesn't. |
| `QuipMac/Services/CloudflareTunnel.swift:213` | `try? fm.createDirectory(...)` for the cloudflared log dir. If it fails, the `--logfile` never materializes, `checkLogForURL()` reads nothing **forever**, and the only symptom is the stall watchdog restarting the tunnel in a loop. |
| `QuipMac/Services/WebSocketServer.swift:587` | `sendToClient` drops a unicast when the client is missing or unauthenticated, silently. The encode failure 8 lines above it logs; this drop doesn't. (The adjacent backpressure drop at `:588` is silent too — same function, outside the grep set.) |
| `QuipMac/QuipMacApp.swift:817` | TTS trigger dropped when the window id no longer resolves. The nearly identical lookup at `:762` treats the same condition as transient and reschedules; this one just returns. |
| `QuipMac/QuipMacApp.swift:839` | `waitForStableContent` returns `nil` only when the window read produced empty text through the whole 2.5 s deadline — i.e. an AppleScript/CG **read failure** — and that failure is discarded. TTS silently doesn't speak. |

## 1.4 Grep artifacts (5) — not swallow sites at all

| Site | Why it matched |
|---|---|
| `QuipMac/Views/SettingsView.swift:742` `@State private var editingPrompt: PromptEntry?` | The type name **`PromptEn`+`try?`** contains the literal pattern. |
| `QuipMac/Views/SettingsView.swift:1919` `let initial: PromptEntry?` | Same. |
| `QuipMac/Services/PushNotificationService.swift:69` | Doc comment describing the old `try?` swallow that `ad979df` fixed. |
| `QuipMac/Services/PushNotificationService.swift:186` | Doc comment quoting `guard !devices.isEmpty else { return }`. |
| `QuipMac/Services/PushNotificationService.swift:203` | Doc comment quoting `try?`. |

## 1.5 BENIGN control flow (185) — full list

### QuipMac/QuipMacApp.swift (35)

| Site | Reason |
|---|---|
| `:22` | Best-effort close of diagnostic log handle. |
| `:24` | Logger's own fallback write — nowhere left to report a logging failure. |
| `:41` | Best-effort close of latency log handle. |
| `:43` | Logger's own fallback write. |
| `:57` | Best-effort close of image-upload log handle. |
| `:59` | Logger's own fallback write. |
| `:292` | Idempotence guard for one-time service startup. |
| `:594` | Re-entrancy guard — skip poll tick while the previous one is still in flight. |
| `:715` | System Settings deep-link URL built from a static literal per enum case; tests assert non-nil for all panes. |
| `:761` | `pendingInput` cleared by another path — documented ordinary cancellation. |
| `:776` | Same cancellation check after a background hop. |
| `:850` | Empty delta = no new terminal output to speak. |
| `:904` | Generation check — a stale TTS stream was superseded; the sibling chunk path logs the drop. |
| `:1027` | No clients connected — skipping the broadcast is the expected no-op. |
| `:1131` | Empty configured roots (ordinary); the decode failure is now logged above it (`88370db`). |
| `:1169` | No subdirectories found; each unreadable root is now logged (`88370db`). |
| `:1936` | Lenient best-effort parse *inside the reporter itself*; nil falls back to "unknown". |
| `:1942` | `LogTransitionGate` dedup — suppresses repeats; the first failure IS reported (`a7752f8`). |
| `:1984` | Best-effort `mkdir`; a real failure surfaces via the WhisperKit init `catch` at `:2003`. |
| `:2175` | `defer` cleanup of a temp zip. |
| `:2222` | Missing log file is reported *into the returned text* ("(missing or unreadable)"). |
| `:2259` | `try? Task.sleep` — cancellation only. |
| `:2430` | Parser: prefix doesn't match — nil means "not this action". |
| `:2434` | Parser: charset/length sanity — nil means malformed token rejected. |
| `:2443` | Parser: prefix doesn't match. |
| `:2460` | Parser: prefix doesn't match. |
| `:2462` | Parser: empty payload after prefix. |
| `:2465` | Parser: out-of-range option number — malformed multi-select rejected. |
| `:2556` | Unreachable — the caller gates on `isAnswerAction` (`:2666`), same parser union. |
| `:2646` | Recursion base case (index past end of key sequence). |
| `:3140` | No frontmost app — documented nil; the phone keeps its last selection. |
| `:3147` | AX focused-window miss is expected for untracked apps; nil by design. |
| `:3151` | AX position miss; documented nil-on-failure, caller deliberately leaves the selection alone. |
| `:3155` | Frontmost app has no tracked windows — ordinary. |
| `:3170` | No candidate within the 50 pt tolerance; nil is deliberately preferred over mis-routing. |

### QuipMac/Services/WebSocketServer.swift (15)

| Site | Reason |
|---|---|
| `:100` | `compactMap` filter — clients without a QA pair are intentionally excluded. |
| `:196` | Re-entrancy guard: server already running. |
| `:227` | Defensive unwrap; `listener` was just assigned non-nil, and the `catch` path already returned + logged. |
| `:304` | `guard let self` in the listener `stateUpdateHandler`. |
| `:359` | `guard let self` in the connection `stateUpdateHandler`. |
| `:464` | `guard let self` in the bind-retry `DispatchWorkItem`. |
| `:514` | Activity touch for an already-removed connection — nothing to update. |
| `:594` | `guard let self` in the send-completion main hop. |
| `:638` | `guard let self` in the broadcast send-completion main hop. |
| `:713` | Parser: nil means the frame isn't an oversized `image_upload`. |
| `:715` | Same parser: unterminated `imageId` in the 4 KB prefix — no match. |
| `:757` | `heartbeat_ack` from an already-removed connection — a late ack, nothing to apply. |
| `:769` | `device_identity` from an already-removed connection. |
| `:922` | `guard let self` in the delayed auth-failure response closure. |
| `:935` | `guard let self` in the `receiveMessage` callback. |

### QuipMac/Services/CloudflareTunnel.swift (13)

| Site | Reason |
|---|---|
| `:102` | `guard let self` in the `NWPathMonitor` closure. |
| `:127` | `guard let self` in the watchdog timer closure. |
| `:131` | Watchdog precondition: not connecting / URL already resolved — nothing to do. |
| `:161` | `guard let self` + intentional-stop check before restart. |
| `:186` | Re-entrancy guard: tunnel already running. |
| `:232` | `guard let self` in the `terminationHandler` main hop. |
| `:239` | `guard let self` + stopped/already-restarted idempotence before auto-restart. |
| `:258` | `guard let self` in the poll timer closure. |
| `:267` | `guard let self` in the health timer closure. |
| `:313` | 1 s poll — the log file not existing yet is ordinary; the next tick retries. |
| `:335` | Parser: a non-JSON log line falls through to the raw-text match by design. |
| `:649` | `guard let self`; UTF-8 decode of just-encoded JSON cannot realistically fail. |
| `:692` | `guard let self`; `cachedServer` is nil only when the tunnel isn't wired to a server. |

### QuipMac/Services/PushNotificationService.swift (8)

| Site | Reason |
|---|---|
| `:19` | Best-effort close of the log file handle after the write already succeeded. |
| `:21` | Logger's own fallback write; the message was already emitted via `NSLog` — reporting would recurse. |
| `:217` | No stored blob = nothing ever persisted (first launch). The **decode** failure is separately reported (`ad979df`). |
| `:232` | No stored prefs blob = never received prefs. Decode failure separately reported (`ad979df`). |
| `:314` | Empty device token is invalid input — nothing to register. |
| `:354` | Nobody registered — nothing to clear. |
| `:435` | Nobody registered — ordinary no-op. |
| `:510` | Nobody registered — ordinary no-op. |

### QuipMac/Services/TerminalStateDetector.swift (16)

| Site | Reason |
|---|---|
| `:14` | UTF-8 encoding of an internal log line cannot realistically fail. |
| `:19` | Best-effort close of the log file handle. |
| `:21` | Logger's own write — documented "failures swallowed; a logger must never crash". |
| `:82` | Re-entrancy guard: already monitoring. |
| `:84` | `guard let self` in the timer closure. |
| `:94` | `guard let self` in the poll-queue closure. |
| `:119` | `guard let self` in the poll-queue closure. |
| `:182` | Non-UTF8 `ps` output → nil; the caller degrades and the poll retries next tick. |
| `:254` | `guard let self` in the process-exit event handler. |
| `:271` | Window untracked by the time its child exited — ordinary race. |
| `:277` | `ps` snapshot unavailable this tick; watches refresh on the next poll. |
| `:507` | `compactMap` lookup miss for a pid that exited mid-walk. |
| `:545` | Pipe cleanup on the `ps` launch-failure path. |
| `:546` | Pipe cleanup on the `ps` launch-failure path. |
| `:552` | Best-effort close after draining `ps` stdout. |
| `:553` | Non-UTF8 `ps` output → nil snapshot; the poll skips this tick. |

### QuipMac/Services/SwrmEventTailer.swift (11)

| Site | Reason |
|---|---|
| `:82` | The events file may not exist yet — documented; returns an empty event list. |
| `:123` | `events.ndjson` may not exist yet — "no events" is ordinary. |
| `:126` | `defer` best-effort file-handle close. |
| `:134` | No new bytes since the cursor — the normal poll outcome. |
| `:174` | `parse()` returns nil for objects that aren't swrm events — a parser miss. |
| `:275` | Cursor file absent on first run — `.zero` is the correct default. |
| `:282` | Best-effort `mkdir`; the write that follows catches and logs its own error. |
| `:353` | `start()` idempotence guard. |
| `:367` | `stop()` idempotence guard. |
| `:440` | Pump skipped when the tailer isn't started. |
| `:452` | `guard let self` in the `ioQueue` callback. |

### QuipMac/Services/WindowManager.swift (9)

| Site | Reason |
|---|---|
| `:152` | Documented: a missing/corrupt pref is treated as an empty list so it can't brick the app. |
| `:168` | Idempotent attach: empty or already-attached session id. |
| `:179` | Idempotent detach: session not in the attached set. |
| `:344` | Focus target no longer in the window list — a stale id from the UI is ordinary. |
| `:460` | App reported zero AX windows — empty-collection early return (the AX *failure* is logged above). |
| `:485` | Toggle target not in the window list — lookup miss. |
| `:850` | Empty live-session list means iTerm isn't running — must not drop ids. |
| `:852` | No stale ids — nothing to reconcile. |
| `:864` | No attached sessions — nothing to enable. |

### QuipMac/Views/SettingsView.swift (9)

| Site | Reason |
|---|---|
| `:166` | `Task.sleep` for the copy-checkmark animation. |
| `:197` | Build-time attrs unavailable → renders "?" in the header; already surfaced. |
| `:624` | Empty blob = never-configured default; the **decode** failure is logged in the `catch` (`88370db`). |
| `:970` | Nil System Settings deep-link URL — ordinary optional unwrap. |
| `:1092` | Empty blob = "no presets saved" default; decode errors logged below (`88370db`). |
| `:1697` | Empty pairing URL — nothing to share yet. |
| `:1800` | UTF-8 encode of the QR payload cannot fail. |
| `:1804` | `CIFilter` output nil → nil image; the caller renders a placeholder. |
| `:2005` | Redundant non-empty check; `canSave` already gates the Save button. |

### QuipMac/Services/PromptLibrary.swift (9)

| Site | Reason |
|---|---|
| `:144` | Listing the prompts dir; nil means nothing to delete (the dir was just created). |
| `:147` | Best-effort delete of reserved `vibecut__` files before rewrite. |
| `:187` | `ensureDirExists` — create-if-needed. |
| `:193` | README already present — seed-once early return. |
| `:219` | Seeding an optional explanatory README — cosmetic best-effort. |
| `:323` | No metadata set → nil meta block — ordinary empty case. |
| `:366` | Cancel handler no-ops when the fd is already closed. |
| `:384` | 150 ms debounce sleep — cancellation is the expected outcome. |
| `:385` | Cancellation check for the debounce task. |

### QuipMac/Services/KeystrokeInjector.swift (5)

| Site | Reason |
|---|---|
| `:134` | Last-outstanding-injection guard; the clipboard restore is idempotent. |
| `:884` | Deliberate refuse-to-guess when the iTerm2 session id is unresolved — documented. |
| `:943` | Unreachable guard — the `.report` case always carries a cause. |
| `:975` | Window number 0 = nothing to capture (the *failure* paths around it now report — `b8279bd`). |
| `:1004` | `defer` cleanup of the temp screenshot file. |

### QuipMac/Services/AuditLogger.swift (5)

| Site | Reason |
|---|---|
| `:38` | Create-if-needed log directory, guarded by a `fileExists` check. |
| `:48` | Size probe for rotation; missing attrs simply means no rotation this pass. |
| `:52` | Best-effort removal of the previous rotated file before rename. |
| `:53` | Best-effort rotation rename; a fresh file is recreated regardless. |
| `:59` | `defer` close of the file handle. |

### QuipMac/Services/SwrmProjectStore.swift (4)

| Site | Reason |
|---|---|
| `:47` | `else`-clause of the `:46` guard — a missing UserDefaults key on first launch is expected. |
| `:123` | Tailer already running for this path — idempotence guard. |
| `:131` | No tailer for this path — nothing to stop. |
| `:137` | `guard let self/tailer` in a weak closure. |

### QuipMac/Services/DiagnosticsBundle.swift (4)

| Site | Reason |
|---|---|
| `:37` | `defer` removes the temp staging dir. |
| `:50` | Non-UTF8 falls through to an explicit verbatim `copyItem` else-branch. |
| `:88` | Size probe on the just-created zip — cap check only. |
| `:91` | Cleanup of an oversize zip immediately before throwing `overSizeCap`. |

### QuipMac/Services/CodeIdentity.swift (4)

| Site | Reason |
|---|---|
| `:46` | Documented degrade-safe nil — the caller errs toward "changed", so failure *signals*. |
| `:50` | Same degrade-safe nil contract. |
| `:54` | Same. |
| `:56` | Missing cdhash key → nil; the caller treats nil as "changed". |

### QuipMac/Services/ClaudeModeDetector.swift (3)

| Site | Reason |
|---|---|
| `:90` | Re-entrancy guard: already monitoring. |
| `:110` | `guard let self` in an async closure. |
| `:122` | `guard let self` in a main-queue closure. |

### QuipMac/Services/APNsMetadataStore.swift (3)

| Site | Reason |
|---|---|
| `:73` | Filename parser: nil = "not an `AuthKey_` file" — expected; callers leave the field alone. |
| `:76` | Same parser: nil for a malformed 10-char key id. |
| `:88` | One-shot migration idempotence flag. |

### QuipMac/Services/TerminalURLExtractor.swift (3)

| Site | Reason |
|---|---|
| `:17` | `NSDataDetector` with a fixed link type cannot fail; empty input returns `[]`. |
| `:25` | `enumerateMatches` nil-match sentinel / non-URL result. |
| `:40` | Scheme filter rejecting bare-TLD false positives — an intended parser reject. |

### QuipMac/Services/KokoroTTS.swift (3)

| Site | Reason |
|---|---|
| `:12` | String→UTF8 encode in the logger cannot realistically fail. |
| `:18` | `defer` closes the log handle. |
| `:220` | Preload skipped when the venv is absent — unavailability is already logged once elsewhere. |

### QuipMac/Views/WindowListSidebar.swift (3)

| Site | Reason |
|---|---|
| `:249` | Nil neighbor → nil action, which disables the menu item. |
| `:352` | No window selected — ordinary early return. |
| `:403` | 1 s delay so a newly spawned terminal window appears before refresh. |

### QuipMac/Views/MainWindow.swift (3)

| Site | Reason |
|---|---|
| `:236` | UTF-8 encode + built-in `CIQRCodeGenerator` — neither realistically nil. |
| `:239` | `CIFilter` output image nil is not a user-actionable failure. |
| `:451` | Bounds check on drag-reorder indices. |

### QuipMac/Services/TailscaleService.swift (2)

| Site | Reason |
|---|---|
| `:75` | Generation/staleness guard: a newer refresh started. |
| `:104` | Generation/staleness guard: a newer refresh superseded this publish. |

### QuipMac/Services/CrashRecoveryAgent.swift (2)

| Site | Reason |
|---|---|
| `:61` | Best-effort `bootout` of a prior version — a non-zero exit is expected and documented. |
| `:70` | Best-effort `bootout` before plist removal; idempotent uninstall. |

### QuipMac/Services/SwrmStoryCoordinator.swift (2)

| Site | Reason |
|---|---|
| `:102` | Weak deps, documented: "when nil, the inject side-effect no-ops". |
| `:154` | Pure matcher returns nil when no window cwd matches. |

### Files contributing one benign site each (14)

| Site | Reason |
|---|---|
| `QuipMac/Models/LayoutPreset.swift:47` | Deprecated parser returns nil for an unknown raw string — documented contract. |
| `QuipMac/Services/APNsClient.swift:206` | Parser: a non-JSON APNs body yields an empty reason string; the caller is already throwing. |
| `QuipMac/Services/AppleScriptRunner.swift:32` | Computed `errorMessage`; a nil error means the script succeeded. |
| `QuipMac/Services/BonjourAdvertiser.swift:19` | Re-entrancy guard: already advertising. |
| `QuipMac/Services/ImageUploadHandler.swift:23` | Format sniffer returns nil for "not an image" — an ordinary non-match. |
| `QuipMac/Services/LogPaths.swift:88` | Create-if-needed log directory on every path access. |
| `QuipMac/Services/LogRedactor.swift:22` | Compiled literal IPv4 regex can never fail to compile. |
| `QuipMac/Services/SecretRedactor.swift:28` | Compiled literal secret regexes — compile cannot fail at runtime. |
| `QuipMac/Services/PINStore.swift:56` | One-shot migration idempotence flag. |
| `QuipMac/Services/QuipLog.swift:61` | `defer` closes the file handle — a deliberate never-crash logger. |
| `QuipMac/Services/TerminalColorManager.swift:88` | Defensive shape check on an in-process color constant that always has 3 components. |
| `QuipMac/Services/VibeCutPromptReader.swift:82` | An absent optional packs directory returns an empty result — ordinary. |
| `QuipMac/Views/LayoutPreview.swift:121` | No active drag → nil target index — ordinary UI state. |
| `QuipMac/Views/MenuBarView.swift:312` | Nil System Settings deep-link URL — ordinary optional unwrap. |

**Benign per-file tally:**
QuipMacApp 35 · TerminalStateDetector 16 · WebSocketServer 15 · CloudflareTunnel 13 ·
SwrmEventTailer 11 · WindowManager 9 · SettingsView 9 · PromptLibrary 9 ·
PushNotificationService 8 · KeystrokeInjector 5 · AuditLogger 5 · SwrmProjectStore 4 ·
DiagnosticsBundle 4 · CodeIdentity 4 · ClaudeModeDetector 3 · APNsMetadataStore 3 ·
TerminalURLExtractor 3 · KokoroTTS 3 · WindowListSidebar 3 · MainWindow 3 ·
TailscaleService 2 · CrashRecoveryAgent 2 · SwrmStoryCoordinator 2 · one-site files 14
= **185**. ✅

**Per-file reconciliation against the raw grep** (benign + real + artifact = enumerated):
QuipMacApp 35+3=38 · WebSocketServer 15+1=16 · TerminalStateDetector 16+0=16 ·
CloudflareTunnel 13+2=15 · SwrmEventTailer 11+3=14 · PushNotificationService 8+2+3=13 ·
SettingsView 9+1+2=12 · PromptLibrary 9+2=11 · WindowManager 9+1=10 · AuditLogger 5+1=6 ·
SwrmProjectStore 4+1=5 · KeystrokeInjector 5+0=5 · DiagnosticsBundle 4 · CodeIdentity 4 ·
WindowListSidebar 3 · MainWindow 3 · VibeCutPromptReader 1+2=3 · TerminalURLExtractor 3 ·
TailscaleService 2+1=3 · KokoroTTS 3 · ClaudeModeDetector 3 · APNsMetadataStore 3 ·
APNsClient 1+2=3 · SwrmStoryCoordinator 2 · CrashRecoveryAgent 2 · MenuBarView 1 ·
LayoutPreview 1 · TerminalColorManager 1 · SecretRedactor 1 · QuipLog 1 · PINStore 1 ·
LogRedactor 1 · LogPaths 1 · ImageUploadHandler 1 · BonjourAdvertiser 1 ·
AppleScriptRunner 1 · LayoutPreset 1 = **212**. ✅

## 1.6 REAL swallow shape, but the failure IS surfaced (12)

These still match the grep — a `try?` or a bare `guard` *is* discarding an error
value — but the failure reaches a human. They are **not** open swallows. Two of
them are loud *because of this sweep*; the other ten were already loud.

| Site | Where the failure surfaces |
|---|---|
| `QuipMacApp.swift:363` | **Made loud by `ceeb999` + `a7752f8`** — malformed frames are logged once per connection by the `WebSocketServer.receiveMessage` sink. |
| `CloudflareTunnel.swift:668` | **Made loud by `ceeb999`** — the `else` branch now logs "sent no auth reply, tunnel client will hang on Connecting". |
| `APNsClient.swift:87` | `try?` drops the serializer's error *detail*, but the `else` throws `APNsError.invalidKey` to the caller. |
| `APNsClient.swift:88` | Same guard, payload half — failure surfaces as a thrown error. |
| `PushNotificationService.swift:479` | Payload-encode failure logged via `quipPushLog` before `continue`. |
| `PushNotificationService.swift:612` | Same. |
| `TailscaleService.swift:165` | `try?` drops the parse error, but a `DetectionError` is surfaced to `lastError` → UI. |
| `SwrmEventTailer.swift:92` | Corrupt interior NDJSON line is logged; only a benign trailing torn line is skipped quietly. |
| `SwrmEventTailer.swift:156` | Corrupt NDJSON line skipped, but `globalLog` records it every time. |
| `VibeCutPromptReader.swift:91` | Unreadable pack counted into `skippedPacks` + printed. |
| `VibeCutPromptReader.swift:92` | Malformed pack JSON counted into `skippedPacks` + printed. |
| `SettingsView.swift:533` | Payload-encode failure appends "could not encode payload" to `testStatus` (user-visible). |

---

# PART 2 — QuipiOS

Source of record: `.superpowers/sdd/task-6b-report.md` (complete, untruncated).
It is reproduced below **in full** so this document stands alone. Its counts:
**313 distinct sites · 44 real swallows · 36 fixed · 8 real-but-unfixed · 269 benign.**

Commits: `b629808` (cert-pin manifest), `fe0a9bd` (remote-PTT audio),
`65ca774` (persisted state + regression tests), `d55be70` (prefs/pairing restore),
`83e2939` (QR scanner + pack export), `0abaa69` (Keychain OSStatus + Watch decode).
Regression tests: `QuipiOS/Tests/PersistenceLoudDropTests.swift` (7 tests, fail
against pre-fix code by construction).

<!-- BEGIN verbatim reproduction of .superpowers/sdd/task-6b-report.md -->

## QuipiOS counts

| | |
|---|---|
| Raw grep lines enumerated | **329** |
| — grep artifacts (not swallow sites at all) | 7 |
| — duplicate lines (one source line matched by two patterns) | 2 |
| — continuation lines of a multi-line guard (same logical site) | 7 |
| **Distinct logical sites classified** | **313** |
| **REAL SWALLOW** | **44** |
| — fixed | **36** |
| — real but deliberately NOT fixed | **8** |
| **BENIGN CONTROL FLOW** | **269** |

Arithmetic check: 329 − 7 − 2 − 7 = **313** logical sites; 44 real + 269 benign = **313**. ✅

Those 36 fixed sites correspond to **34 distinct code locations edited** — the two
`KeychainBackendPINs.read(...)` *call sites* (`BackendConnectionManager:171` and
`:429`) are both resolved by the single fix at the reader (`KeychainBackendPINs:28`).

- Artifact lines: 94, 95, 96, 105, 106, 110 (the substring `try?` inside the type
  name `PromptEn`**`try?`**) and 264 (a *comment* describing the existing loud-drop helper).
- Duplicate lines: 44 (= 43), 118 (= 117).
- Continuation lines: 23, 27, 91, 169, 215, 309, 313.

## QuipiOS headline finds

1. **`WhisperAudioSender.convert()`** captured the `NSError` out of
   `AVAudioConverter.convert(to:error:)` and **threw it away**, and `appendBuffer`
   did `guard let resampled = convert(buffer) else { return }`. A broken resampler
   dropped **every mic buffer in total silence** — and because the symptom is
   "Whisper came back empty", it points the investigator at the *Mac*.
2. **Both Keychain readers** conflated `errSecItemNotFound` (ordinary) with real
   `OSStatus` failures — notably `-25308 errSecInteractionNotAllowed` (keychain still
   locked, and `BackendConnectionManager` auto-connects at launch *before* first
   unlock) and `-34018 errSecMissingEntitlement` (access group lost across a resign).
   Result: auth silently skipped ("connected but not authenticated"), or a **new
   device ID minted**, losing paired identity *and* the prefs backup.
3. **QR pairing scanner** — `guard let device = ..., let input = try? AVCaptureDeviceInput(device:) else { return }`
   returned from `viewDidLoad` having built nothing. Camera permission denied /
   camera busy / no camera all rendered as an **unexplained black sheet that never
   scans**, with a user actively waiting on it.

## The 8 QuipiOS real swallows deliberately NOT fixed

| Site | Why not fixed |
|---|---|
| `BackendSession:61` `try? decode(QAPair)` | QA-pair restore. Symptom (no side-by-side layout) is immediately visible; recovery is one long-press. |
| `BackendSession:71` `try? encode(pair)` | Same, persist side. |
| `QuipApp:4697` `(try? decode(MRU)) ?? [:]` | Prompt-MRU sort only — degrades to alphabetical. Cosmetic, self-evident, non-breaking. |
| `QuipApp:4715` `(try? decode(MRU)) ?? [:]` | Same. |
| `QuipApp:4724` `try? encode(mru)` | Same — a usage timestamp goes unrecorded. |
| `BackendConnectionManager:496` cap guard | Only reachable with 4 **pinned** backends (primary path LRU-evicts first). Correct fix is a UX decision ("unpin one first"), not a log. → follow-up #1. |
| `BackendConnectionManager:567` cap guard | Same; `addPaired` returns nil, `applyPairingPayload` skips the PIN write + `setActive` but still calls `doConnect()`. → follow-up #1. |
| `SpeechService:792` `recognizer.isAvailable` | `beginCaptionTask` — captions are *supplementary*; the remote Whisper path still carries the real transcription. Site sits inside the protected PTT path. |

## What QuipiOS deliberately did NOT touch

- **~24 `guard isAuthenticated else { return }`** in `WebSocketClient` send paths.
  Connection state is *already* surfaced globally in `ConnectionStatusBar`.
- **~25 `guard let self, let session else { return }`** weak-self teardown guards in
  `BackendConnectionManager`.
- **~14 `guard session.backendID == manager.activeBackendID`** multi-backend routing filters.
- **All `try? await Task.sleep`** — cancellation, by definition not an error.
- **`SpeechService:582` `try? setActive(false, .notifyOthersOnDeactivation)`** — failure
  is *expected and already documented in-code*. A textbook benign-by-design site that a
  mechanical rewriter would have "fixed".
- **Prompt-MRU decode/encode** (`QuipApp:4697/4715/4724`).

### Hard constraints honored

- **PTT audio-session lifecycle:** the two `try? session.setActive(true)` sites
  (`SpeechService:541`, `:751`) are **LOG-ONLY**. Control flow is byte-for-byte
  unchanged — the cold-start path still falls through to `audioEngine.start()` exactly
  as before. `:751`'s `try?` was specifically *not* promoted to the enclosing `do`'s
  `try`, because that would have skipped `audioEngine.start()` on activation failure.
- **Volume-button KVO:** not touched (`HardwareButtonHandler` — all sites benign).
- **`InFlightAction`'s "a late reply cannot resurrect a timed-out action" rule:** not
  weakened. `InFlightAction:67` and the stale-token guards at `QuipApp:8996`,
  `SpeechService:251`, `RemoteSpeechSession:45/60` are *correct* and left as-is.
- **`MessageCoder.encode`** lives in `Shared/` (Mac-side blast radius), so its two
  nil-returns are reported at the **QuipiOS call sites** rather than by changing the
  shared coder.

---

## QuipiOS — COMPLETE CLASSIFICATION, all 329 enumerated lines

Legend: **[FIX]** = real swallow, fixed · **[REAL-NF]** = real swallow, not fixed
(reason given) · **[BENIGN]** = ordinary control flow · **[ARTIFACT]** = grep false
positive · **[DUP]** = same source line already listed

### Grep artifacts (7) — not swallow sites at all

| Line | Site | Class |
|---|---|---|
| 94 | `QuipApp:8569` `@State private var editing: PromptEntry?` | **[ARTIFACT]** type annotation, not `try?` |
| 95 | `QuipApp:8572` `@State private var pendingGeneratedDraft: PromptEntry?` | **[ARTIFACT]** same |
| 96 | `QuipApp:8573` `@State private var generatedDraft: PromptEntry?` | **[ARTIFACT]** same |
| 105 | `QuipApp:8903` `let initial: PromptEntry?` | **[ARTIFACT]** same |
| 106 | `QuipApp:8904` `var draft: PromptEntry? = nil` | **[ARTIFACT]** same |
| 110 | `QuipApp:9035` `private var metadataSource: PromptEntry? {` | **[ARTIFACT]** same |
| 264 | `WebSocketClient:1057` | **[ARTIFACT]** a *comment* describing the existing loud-drop helper |

Duplicates: line **44** = `QuipApp:4885` (dup of 43); line **118** = `QuipWatch:87` (dup of 117). **[DUP]**

### QuipiOS/Models/BackendSession.swift (2)

| Line | Site | Class |
|---|---|---|
| 1 | `:61` `try? decode(QAPair)` | **[REAL-NF]** QA-pair restore. Decode failure → no side-by-side layout. Symptom is *immediately visible*, recovery is one long-press. |
| 2 | `:71` `try? encode(pair)` | **[REAL-NF]** Same, persist side. |

### QuipiOS/QuipApp.swift (111 lines)

#### Fixed

| Line | Site | Class |
|---|---|---|
| 21 | `:3841` `try? encode(phoneFrameOverrides)` | **[FIX]** `persistOverrides` — encode failure silently lost drag positions. |
| 22 | `:3852` `try? decode([String:WindowFrame])` | **[FIX]** `loadOverrides` — corrupt blob silently reset saved window positions. |
| 23 | `:3853` `else { return }` | **[FIX]** continuation of site 22. |
| 26 | `:3924` `try? decode([String])` | **[FIX]** `loadWindowOrder` — corrupt blob silently lost saved card order. |
| 27 | `:3925` `else { return }` | **[FIX]** continuation of site 26. |
| 28 | `:3942` `try? encode(phoneWindowOrder)` | **[FIX]** `persistWindowOrder`. |
| 32 | `:4194` `try? decode([SavedConnection])` | **[FIX]** `loadRecents`. |
| 33 | `:4200` `try? encode(recentConnections)` | **[FIX]** `saveRecents`. |
| 43 | `:4885` `try? AVCaptureDeviceInput(device:)` | **[FIX]** **QR scanner** — camera failure = unexplained black sheet. Now draws cause + next step into the view, and logs. |
| 64 | `:6099` `try? decode([QuickSlot])` | **[FIX]** `QuickSlotStore.decode` — corrupt blob silently replaced the user's button row with defaults. |
| 65 | `:6105` `try? encode(slots)` | **[FIX]** `QuickSlotStore.encode` — failure persisted `"[]"` over live data (destructive wipe). |
| 66 | `:6156` `try? decode([CustomButton])` | **[FIX]** `CustomButtonStore.decode` — same, custom buttons vanish. |
| 67 | `:6162` `try? encode(buttons)` | **[FIX]** `CustomButtonStore.encode` — same destructive wipe. |
| 75 | `:7040` `try? pack.writeToTemp` | **[FIX]** **Export buttons** — failure made the Share button a permanent no-op. Now alerts. |
| 90 | `:849` `try? decode([SavedConnection])` | **[FIX]** Recents restore-from-Mac — decode failure aborted restore silently. |
| 91 | `:850` `!restored.isEmpty else { return }` | **[FIX]** Continuation of 90; empty is now *explicitly* benign, corrupt now logs. |
| 92 | `:852` `.flatMap { try? decode }` | **[FIX]** Local recents blob corrupt → silently dropped from the merge. |
| 93 | `:854` `try? encode(merged)` | **[FIX]** Merge result failed to persist → recents gone next launch. |
| 97 | `:8683` `try? pack.writeToTemp` | **[FIX]** **Export prompts** — same dead-Share-button. Now alerts. |

#### Real but not fixed

| Line | Site | Class |
|---|---|---|
| 39 | `:4697` `(try? decode(MRU)) ?? [:]` | **[REAL-NF]** Prompt-MRU sort order only. Degrades to alphabetical — cosmetic, self-evident, non-breaking. |
| 40 | `:4715` `(try? decode(MRU)) ?? [:]` | **[REAL-NF]** Same. |
| 41 | `:4724` `try? encode(mru)` | **[REAL-NF]** Same — usage timestamp not recorded. |

#### Benign control flow

| Line | Site | Reasoning |
|---|---|---|
| 3 | `:1675` backendID == activeBackendID | Multi-backend routing filter — a message from a non-active backend is ordinary. |
| 4 | `:1683` backendID filter | Same. |
| 5 | `:1713` `deniedCount > 0, !hasAutoShownPerms` | Auto-show-once gate. |
| 6 | `:1728` `note.object as? PairingPayload` | Cast on a notification the app itself posts — internal invariant. |
| 7 | `:1753` `count > 0, !promptsAutoEnabledOnce` | One-shot gate. |
| 8 | `:2068` `!info.isAlreadyTracked` | Dedupe. |
| 9 | `:2594` `pinText.count >= 4` | Form validation; UI disables the button. |
| 10 | `:3062` `!isQAModeActive` | Mode gate. |
| 11 | `:3067` `ordered.count > 1` | Nothing to reorder. |
| 12 | `:3132` `let windowId = selectedWindowId` | No window selected — ordinary. |
| 13 | `:3134` `!text.isEmpty \|\| hasPendingImage` | Nothing to send. |
| 14 | `:3166` `let wid = selectedWindowId` | Ordinary. |
| 15 | `:331` `url.scheme == "quip"` | URL-handler filter. |
| 16 | `:3450` `containerWidth > 0` | Layout not measured yet. |
| 17 | `:3548` `containerHeight > 0` | Same. |
| 18 | `:3761` `let mode = phoneLayoutOverride, total > 0` | No override set. |
| 19 | `:3769` `total > 0, index >= 0, index < total` | Bounds check. |
| 20 | `:3813` `count > 0` | Empty collection. |
| 24 | `:3876` `total > 0` | Empty collection. |
| 25 | `:3900` `next != current` | No-op change. |
| 29 | `:4007` `!typed.isEmpty` | Empty input. |
| 30 | `:4044` `try? await Task.sleep` | Cancellation. |
| 31 | `:4106` `!urlText.isEmpty` | Form validation. |
| 34 | `:4242` `scenes.first as? UIWindowScene` | No active scene (backgrounded) — ordinary. |
| 35 | `:4320` `let wid = selectedWindowId` | Ordinary. |
| 36 | `:4366` `text.count >= 2, text.first == "/"` | Not a slash command. |
| 37 | `:4373` `button.isSlashCommand, button != .slash` | Filter. |
| 38 | `:4655` `let wid = selectedWindowId, !wid.isEmpty` | Ordinary. |
| 42 | `:4734` `let wid = selectedWindowId` | Ordinary. |
| 45 | `:4906` `let str = obj.stringValue` | Metadata object without a string payload — ordinary for non-QR objects. |
| 46 | `:5058` `guard allowed` | Permission/Labs gate. |
| 47 | `:5115` `try? NSDataDetector(types: .link)` | Compile-time-constant pattern; cannot fail at runtime. |
| 48 | `:5121` `let range = Range(match.range, in: attr)` | Range conversion on a match the detector just produced. |
| 49 | `:5129` `else { return }` | Linkify loop continuation. |
| 50 | `:5195` `!chosen.isEmpty` | Empty selection. |
| 51 | `:524` backendID filter | Ordinary. |
| 52 | `:5513` `guard hasAutosuggest` | Feature gate. |
| 53 | `:5650` `guard isPinnedToBottom` | Scroll behavior. |
| 54 | `:569` backendID filter | Ordinary. |
| 55 | `:571` `windows.contains(id == windowId)` | Window closed — ordinary. |
| 56 | `:5728` `abs(dx) > 90, abs(dx) > abs(dy)*2` | Swipe-gesture threshold. |
| 57 | `:583` backendID filter | Ordinary. |
| 58 | `:586` `manager.active.qaPair == nil` | Mode gate. |
| 59 | `:587` `guard followFrontmost` | Pref gate. |
| 60 | `:589` `windows.contains(wid)` | Window closed. |
| 61 | `:597` backendID filter | Ordinary. |
| 62 | `:602` backendID filter | Ordinary. |
| 63 | `:607` backendID filter | Ordinary. |
| 68 | `:620` backendID filter | Ordinary. |
| 69 | `:637` backendID filter | Ordinary. |
| 70 | `:6394` `try? await Task.sleep` | Cancellation. |
| 71 | `:657` backendID filter | Ordinary. |
| 72 | `:6588` `let token = pushRegistration.deviceToken` | APNs token not yet issued — ordinary early-launch state. |
| 73 | `:6833` `let token = pushRegistration.deviceToken` | Same. |
| 74 | `:696` `index >= 0, index < windows.count` | Bounds check. |
| 76 | `:709` backendID filter | Ordinary. |
| 77 | `:738` backendID filter | Ordinary. |
| 78 | `:753` backendID filter | Ordinary. |
| 79 | `:755` `guard ttsEnabled` | Pref gate. |
| 80 | `:761` backendID filter | Ordinary. |
| 81 | `:763` `guard ttsEnabled` | Pref gate. |
| 82 | `:769` backendID filter | Ordinary. |
| 83 | `:778` backendID filter | Ordinary. |
| 84 | `:7840` `guard !labelEdited` | Don't clobber a user edit. |
| 85 | `:7858` `guard let initial` | Create-new flow (nil = new). |
| 86 | `:8217` `try? FileManager.removeItem(at: dest)` | Pre-delete before copy — "not there" IS success. |
| 87 | `:8268` `guard client.isAuthenticated` | Not connected yet; state surfaced in the status bar. |
| 88 | `:8278` `guard client.isAuthenticated` | Same. |
| 89 | `:828` backendID filter | Ordinary. |
| 98 | `:8756` `isConnected && isAuthenticated` | Same as 87. |
| 99 | `:8768` `try? await Task.sleep` | Cancellation (deadline timer). |
| 100 | `:8769` `guard syncing` | Timeout no-op if the sync already finished — correct deadline pattern. |
| 101 | `:8791` `try? await Task.sleep` | Cancellation. |
| 102 | `:8844` `let wid = windowIdProvider(), !wid.isEmpty` | Ordinary. |
| 103 | `:8879` `try? await Task.sleep` | Cancellation. |
| 104 | `:8880` `pendingDeleteIDs.contains(entry.id)` | Timeout no-op if already acked. The *timeout* path DOES report (`deleteErrorMessage` → "Delete failed" alert). |
| 107 | `:8977` `!id.isEmpty, !bodyText.trimmed.isEmpty` | Form validation. |
| 108 | `:8995` `try? await Task.sleep` | Cancellation. |
| 109 | `:8996` `pendingMessageId == messageId` | **Stale-reply guard — correct and deliberately untouched.** |
| 111 | `:9040` `let ack = latestAck, ack.messageId == pendingMessageId` | Ack correlation. |
| 112 | `:916` `guard isRecording` | State gate. |
| 113 | `:943` `guard let windowId` | Ordinary. |

### QuipiOS/QuipWatch/QuipWatchApp.swift (5)

| Line | Site | Class |
|---|---|---|
| 114 | `:69` `message["windows"] as? Data` | **[BENIGN]** WCSession message without a `windows` key = a different message type. |
| 115 | `:75` `userInfo["windows"] as? Data` | **[BENIGN]** Same. |
| 116 | `:81` `appContext["windows"] as? Data` | **[BENIGN]** Same. |
| 117 | `:87` `try? decode([WatchWindowState])` | **[FIX]** The phone DID send a payload that won't decode (schema drift watch↔phone). Watch stuck on an empty/stale list forever, looking exactly like "the phone never sent anything". |
| 118 | `:87` | **[DUP]** of 117. |

### QuipiOS/Services/BackendConnectionManager.swift (54)

| Line | Site | Class |
|---|---|---|
| 166 | `:636` `try? decode([PairedBackend])` | **[FIX]** `loadPaired` — a corrupt blob dropped **every paired Mac** and dumped the user back on the pairing screen. |
| 167 | `:721` `try? encode(paired)` | **[FIX]** `savePaired` — pairing never persisted, gone on next launch. |
| 168 | `:737` `try? decode([PairedBackend])` | **[FIX]** `mergeRestoredBackends` — restore-from-Mac aborted in silence. |
| 169 | `:738` `!restored.isEmpty else { return }` | **[FIX]** Continuation of 168. |
| 147 | `:171` `let pin = KeychainBackendPINs.read(...)` | **[FIX]** *(fixed at the reader — see KeychainBackendPINs:28)*. A real OSStatus failure silently skipped auth. |
| 161 | `:429` `let pin = KeychainBackendPINs.read(...)` | **[FIX]** Same reader; same fix. |
| 162 | `:496` `paired.count < maxPairedBackends` | **[REAL-NF]** Silently refuses to add a 5th backend. Only reachable when all 4 are *pinned*. Needs a UX decision, not a log. **Follow-up.** |
| 163 | `:567` `paired.count < maxPairedBackends else nil` | **[REAL-NF]** Same; `addPaired` returns nil and `applyPairingPayload` then skips the PIN write + setActive but still calls `doConnect()`. |
| 119 | `:1014` `let session = sessions[id]` | **[BENIGN]** Session gone. |
| 120 | `:1016` `let lan = preferredLANURL(from:)` | **[BENIGN]** No LAN URL among candidates — ordinary in Tailscale-only. |
| 121 | `:1053` `let m = lastSeenLayoutMonitorName, !m.isEmpty` | **[BENIGN]** Never seen a monitor name. |
| 122 | `:1108` `!reaped.isEmpty` | **[BENIGN]** Empty collection. |
| 123 | `:1123` `let backend = paired.first(id)` | **[BENIGN]** Lookup miss. |
| 124 | `:1146` `!urls.isEmpty` | **[BENIGN]** Empty collection. |
| 125–144 | `:1168, 1201, 1206, 1219, 1232, 1238, 1243, 1251, 1256, 1262, 1268, 1274, 1279, 1291, 1317, 1439, 1444, 1453, 1466, 1470` — `guard let self, let session` ×20 | **[BENIGN]** Weak-self callback teardown guards. |
| 145 | `:153` `sessions[id] == nil` | **[BENIGN]** Already spawned (idempotent). |
| 146 | `:162` `!activeBackendID.isEmpty` | **[BENIGN]** No active backend. |
| 148 | `:184` `paired.firstIndex(activeBackendID)` | **[BENIGN]** Lookup miss. |
| 149 | `:284` `let session = sessions[activeBackendID]` | **[BENIGN]** Ordinary. |
| 150 | `:312` `try? await Task.sleep` | **[BENIGN]** Cancellation. |
| 151 | `:315` `try? await Task.sleep` | **[BENIGN]** Cancellation. |
| 152 | `:323` `UserDefaults.bool(autoSwapDefaultsKey)` | **[BENIGN]** Feature off. |
| 153 | `:327` `let currentURL = session.client.serverURL` | **[BENIGN]** Not connected. |
| 154 | `:329` `candidates.count > 1` | **[BENIGN]** Nothing to swap to. |
| 155 | `:336` `) else { return nil }` | **[BENIGN]** `URLSwapPolicy` returned no recommendation — an ordinary verdict. |
| 156 | `:387` `pathMonitor == nil` | **[BENIGN]** Idempotent start. |
| 157 | `:391` `guard let self` | **[BENIGN]** Teardown. |
| 158 | `:407` `paired.firstIndex(id)` | **[BENIGN]** Lookup miss. |
| 159 | `:408` `paired[i].enabled != enabled` | **[BENIGN]** No-op change. |
| 160 | `:412` `let session = sessions[id]` | **[BENIGN]** Ordinary. |
| 164 | `:613` `let entry = paired.first(id)` | **[BENIGN]** Lookup miss. |
| 165 | `:615` `!urls.isEmpty` | **[BENIGN]** Empty collection. |
| 170 | `:776` `!existing.contains(url) else nil` | **[BENIGN]** Dedupe. |
| 171 | `:986` `paired.firstIndex(backendID)` | **[BENIGN]** Lookup miss. |
| 172 | `:988` `merged != paired[i].urlsInOrder` | **[BENIGN]** No change. |

### QuipiOS/Services/BonjourBrowser.swift (7)

| Line | Site | Class |
|---|---|---|
| 173 | `:135` `sender.txtRecordData() else nil` | **[BENIGN]** Service without a TXT record. |
| 174 | `:137` `dict["did"], String(data:), !id.isEmpty` | **[BENIGN]** Older Mac without the device-id TXT key. |
| 175 | `:142` `sender.addresses` | **[BENIGN]** Not yet resolved. |
| 176 | `:54` `!isSearching` | **[BENIGN]** Idempotent start. |
| 177 | `:62` `guard let self` | **[BENIGN]** Teardown. |
| 178 | `:79` `try? await Task.sleep(4s)` | **[BENIGN]** Cancellation. |
| 179 | `:83` `isSearching: self.isSearching) else return` | **[BENIGN]** Search already stopped. |

> Observation (not an enumerated site, so not counted): `NetServiceBrowser`'s
> `didNotSearch(errorDict:)` delegate is worth checking — a Bonjour browse that fails
> to *start* is an absence, not a swallow, so it fell outside this grep.

### QuipiOS/Services/ConnectionMetrics.swift (1)

| Line | Site | Class |
|---|---|---|
| 180 | `:47` `!timeToAuthMsSamples.isEmpty else nil` | **[BENIGN]** No samples yet. |

### QuipiOS/Services/HardwareButtonHandler.swift (12) — all benign, protected area

| Line | Site | Class |
|---|---|---|
| 181 | `:143` `self.windowCount > 0` | **[BENIGN]** No windows. |
| 182 | `:155` `guard let self` | **[BENIGN]** Teardown. |
| 183 | `:156` `applicationState == .active` | **[BENIGN]** Backgrounded. |
| 184 | `:168` `RouteChangeReason(rawValue:)` | **[BENIGN]** Route-change filter — correctly restricted to hardware reasons. |
| 185 | `:198` `let target = savedVolume` | **[BENIGN]** Nothing saved. |
| 186 | `:225` `volumeObservation != nil` | **[BENIGN]** KVO not active. **Untouched per hard constraint.** |
| 187 | `:312` `guard let self, self.isPTTActive` | **[BENIGN]** Not in PTT. |
| 188 | `:341` `let volumeView = shared` | **[BENIGN]** Ordinary. |
| 189 | `:68` `windowCount > 0` | **[BENIGN]** No windows. |
| 190 | `:72` `volumeObservation == nil` | **[BENIGN]** Idempotent KVO start. **Untouched per hard constraint.** |
| 191 | `:92` `change.newValue, change.oldValue` | **[BENIGN]** KVO change dict. |
| 192 | `:94` `guard let self` | **[BENIGN]** Teardown. |

### QuipiOS/Services/InFlightAction.swift (2)

| Line | Site | Class |
|---|---|---|
| 193 | `:52` `state != .inFlight` | **[BENIGN]** Idempotent start. |
| 194 | `:67` `state == .inFlight` | **[BENIGN]** **The "late reply cannot resurrect a timed-out action" rule. Correct as written; deliberately untouched.** |

### QuipiOS/Services/KeychainBackendPINs.swift (2)

| Line | Site | Class |
|---|---|---|
| 195 | `:28` `status == errSecSuccess, ... else nil` | **[FIX]** Conflated `errSecItemNotFound` (ordinary) with real OSStatus failures (`-25308` locked keychain, `-34018` lost entitlement). Auth silently skipped → "connected but not authenticated" with no explanation. |
| 196 | `:57` `oldID != newID, let pin = read(oldID)` | **[BENIGN]** Rename no-op. |

### QuipiOS/Services/KeychainDeviceID.swift (1)

| Line | Site | Class |
|---|---|---|
| 197 | `:37` `status == errSecSuccess, ... else nil` | **[FIX]** Same conflation. Worse consequence: a **new device ID gets minted**, so the Mac sees a brand-new device and the phone loses paired identity + prefs backup. |

### QuipiOS/Services/LatencyProbeService.swift (6)

| Line | Site | Class |
|---|---|---|
| 198 | `:101` `let port = url.port ?? defaultPort(for:)` | **[BENIGN]** Unparseable URL — probe skipped, non-critical telemetry. |
| 199 | `:119` `NWEndpoint.Port(rawValue:) else nil` | **[BENIGN]** Same. |
| 200 | `:129` `guard !resumed` | **[BENIGN]** Continuation double-resume guard — correct. |
| 201 | `:163` `guard let client` | **[BENIGN]** Teardown. |
| 202 | `:67` `try? await Task.sleep` | **[BENIGN]** Cancellation. |
| 203 | `:70` `try? await Task.sleep` | **[BENIGN]** Cancellation. |

### QuipiOS/Services/LiveActivityService.swift (2)

| Line | Site | Class |
|---|---|---|
| 204 | `:100` `let activity = activities[windowId]` | **[BENIGN]** No Live Activity for that window. |
| 205 | `:150` `let activity = macPermsActivity` | **[BENIGN]** Not showing. |

### QuipiOS/Services/PendingImageState.swift (3)

| Line | Site | Class |
|---|---|---|
| 206 | `:128` `try? await Task.sleep(10s)` | **[BENIGN]** Watchdog timer; cancellation. |
| 207 | `:129` `guard let self, uploadState == .uploading` | **[BENIGN]** Watchdog no-op if the upload already finished — correct deadline pattern (the *timeout* path reports via `ImageUploadFailure`). |
| 208 | `:145` `try? await Task.sleep` | **[BENIGN]** Cancellation. |

### QuipiOS/Services/PendingMacRequest.swift (5)

| Line | Site | Class |
|---|---|---|
| 209 | `:47` `guard case .failed(...) = state else nil` | **[BENIGN]** Accessor. |
| 210 | `:57` `guard !isInFlight` | **[BENIGN]** Idempotent. |
| 211 | `:66` `try? await Task.sleep` | **[BENIGN]** Cancellation. |
| 212 | `:67` `guard !Task.isCancelled` | **[BENIGN]** Cancellation. |
| 213 | `:85` `guard action.tick(now:)` | **[BENIGN]** Deadline tick — the failure path here *does* carry cause + next step. The reference contract, working as intended. |

### QuipiOS/Services/PreferencesSyncService.swift (7)

| Line | Site | Class |
|---|---|---|
| 214 | `:104` `try? decode(PreferencesSnapshot)` | **[FIX]** `hydrateFromICloud` — schema drift after an app update silently dropped the whole iCloud snapshot. |
| 215 | `:105` `else { return }` | **[FIX]** Continuation of 214. |
| 216 | `:114` `MessageCoder.encode(msg) else return` | **[FIX]** `requestRestore` — encode failure meant prefs were never even *requested* from the Mac; the phone just never spoke. |
| 218 | `:172` `try? encode(snapshot)` | **[FIX]** iCloud mirror never written. |
| 219 | `:178` `MessageCoder.encode(msg) else return` | **[FIX]** `pushSnapshot` — prefs never backed up to the Mac. |
| 217 | `:153` `Date() >= suppressUntil` | **[BENIGN]** Suppression window — correct, prevents a restore→sync ricochet. |
| 220 | `:49` `observer == nil` | **[BENIGN]** Idempotent. |

### QuipiOS/Services/PushNotificationCenter.swift (3)

| Line | Site | Class |
|---|---|---|
| 221 | `:23` `!windowsNeedingAttention.contains(windowId)` | **[BENIGN]** Dedupe. |
| 222 | `:29` `windowsNeedingAttention.contains(windowId)` | **[BENIGN]** Not present — ordinary. |
| 223 | `:37` `!windowsNeedingAttention.isEmpty` | **[BENIGN]** Empty collection. |

### QuipiOS/Services/RemoteSpeechSession.swift (3)

| Line | Site | Class |
|---|---|---|
| 224 | `:45` `sessionId == self.sessionId, !didResolve` | **[BENIGN]** Stale-session guard — correct, must not weaken. |
| 225 | `:59` `try? await Task.sleep` | **[BENIGN]** Cancellation. |
| 226 | `:60` `guard let self, !self.didResolve` | **[BENIGN]** Timeout no-op if already resolved — correct deadline pattern. |

### QuipiOS/Services/SilentModeDetector.swift (1)

| Line | Site | Class |
|---|---|---|
| 227 | `:34` `try? FileManager.removeItem(at: url)` | **[BENIGN]** Temp-file cleanup — "not there" IS success. |

### QuipiOS/Services/SpeechService.swift (27)

| Line | Site | Class |
|---|---|---|
| 228 | `:10` `try? String(contentsOf: url)` | **[FIX]** `DictationVocab.load` — a vocab file that *exists but is unreadable* left dictation running with an EMPTY vocabulary, mis-transcribing every custom term. |
| 240 | `:541` `try? session.setActive(true)` | **[FIX — LOG-ONLY]** `arm()`. Activation failure → engine taps a dead session → PTT records pure silence, indistinguishable from a working mic. **Control flow byte-for-byte unchanged.** |
| 249 | `:751` `try? session.setActive(true)` | **[FIX — LOG-ONLY]** Cold-start path. Deliberately kept as an *inner* catch rather than promoting to the outer `try`, because throwing would skip `audioEngine.start()`. |
| 251 | `:792` `let recognizer = ..., recognizer.isAvailable else return` | **[REAL-NF]** `beginCaptionTask` — an unavailable recognizer silently starts no caption task. Captions are *supplementary*; the remote Whisper path still carries the transcription. |
| 243 | `:582` `try? setActive(false, .notifyOthersOnDeactivation)` | **[BENIGN]** **Failure is expected and already documented in-code**: "Best-effort — if TTS is mid-playback the session will refuse to deactivate." |
| 229 | `:107` `interruptionObserver == nil` | **[BENIGN]** Idempotent. |
| 230 | `:112` `guard let self` | **[BENIGN]** Teardown. |
| 231 | `:114` `InterruptionType(rawValue:)` | **[BENIGN]** Notification payload filter. |
| 232 | `:211` `guard let self` | **[BENIGN]** Teardown. |
| 233 | `:250` `guard let self` | **[BENIGN]** Teardown. |
| 234 | `:251` `activeSessionToken == sessionToken` | **[BENIGN]** Stale-session guard — correct. |
| 235 | `:321` `guard let self, let pending = pendingStopCompletion` | **[BENIGN]** Nothing pending. |
| 236 | `:341` `guard !isRecording` | **[BENIGN]** Idempotent. |
| 237 | `:437` `backgroundTaskId == .invalid` | **[BENIGN]** Idempotent begin. |
| 238 | `:445` `backgroundTaskId != .invalid` | **[BENIGN]** Idempotent end. |
| 239 | `:539` `guard !self.isArmed` | **[BENIGN]** Idempotent arm. |
| 241 | `:547` `guard let self` | **[BENIGN]** Teardown. |
| 242 | `:566` `guard self.isArmed` | **[BENIGN]** Not armed. |
| 244 | `:638` `guard let self` | **[BENIGN]** Teardown. |
| 245 | `:693` `guard !self.isFlushing` | **[BENIGN]** Re-entrancy guard. |
| 246 | `:694` `!isStopping \|\| recognitionTask != nil` | **[BENIGN]** State gate. |
| 247 | `:706` `guard let self` | **[BENIGN]** Teardown. |
| 248 | `:718` `guard let self` | **[BENIGN]** Teardown. |
| 250 | `:767` `guard let self` | **[BENIGN]** Teardown. |
| 252 | `:799` `guard let self` | **[BENIGN]** Teardown. |
| 253 | `:826` `guard self.isArmed` | **[BENIGN]** Not armed. |
| 254 | `:835` `guard let self` | **[BENIGN]** Teardown. |

### QuipiOS/Services/TranscriptCorrector.swift (1)

| Line | Site | Class |
|---|---|---|
| 255 | `:63` `try? NSRegularExpression(pattern:)` | **[BENIGN]** Compile-time-constant pattern; cannot fail at runtime, and `TranscriptCorrectorTests` would catch it if it could. |

### QuipiOS/Services/URLSwapPolicy.swift (3)

| Line | Site | Class |
|---|---|---|
| 256 | `:53` `let currentHost = currentURL.host else nil` | **[BENIGN]** No host — no recommendation. |
| 257 | `:55` `currentSamples.count >= minSamplesPerURL` | **[BENIGN]** Insufficient data — an ordinary verdict, not a failure. |
| 258 | `:57` `currentAvg > 0` | **[BENIGN]** Same. |

### QuipiOS/Services/WatchSyncService.swift (4)

| Line | Site | Class |
|---|---|---|
| 259 | `:38` `WCSession.isSupported()` | **[BENIGN]** iPad / no watch. |
| 260 | `:48` `WCSession.isSupported()` | **[BENIGN]** Same. |
| 261 | `:50` `activationState == .activated` | **[BENIGN]** Not activated yet. |
| 262 | `:51` `isPaired, isWatchAppInstalled` | **[BENIGN]** No watch — ordinary. |

### QuipiOS/Services/WebSocketClient.swift (56)

| Line | Site | Class |
|---|---|---|
| 308 | `:78` `try? Data(contentsOf: url)` | **[FIX]** Cert-pin Documents override — a file the user/MDM deliberately placed was silently ignored, then every connection failed a pin check for unexplained reasons. |
| 309 | `:79` `try? decode(PinManifest)` | **[FIX]** Same site, decode half. |
| 311 | `:88` `try? Data(contentsOf: url)` | **[FIX]** Bundled `CertPins.json` unusable → silent fallback to hardcoded pins. |
| 313 | `:89` `try? decode(PinManifest)` | **[FIX]** Same site, decode half. |
| 265–288 | `:1154, 1160, 1166, 1172, 1177, 1182, 1189, 1194, 1199, 1215, 1220, 1226, 1232, 1237, 1242, 1247, 1252, 1261, 1268, 1274, 1281, 1288, 1295, 1302` — `guard isAuthenticated else { return }` ×24 | **[BENIGN]** Send-path gate. Not-authenticated is *already* surfaced globally in `ConnectionStatusBar`. |
| 263 | `:1002` `guard let self` | **[BENIGN]** Teardown. |
| 289 | `:1337` `try? await Task.sleep(10s)` | **[BENIGN]** Keepalive ping; cancellation. |
| 290 | `:1338` `!Task.isCancelled, let self, let task` | **[BENIGN]** Teardown. |
| 291 | `:1340` `!Task.isCancelled` | **[BENIGN]** Cancellation. |
| 292 | `:1360` `!intentionalDisconnect` | **[BENIGN]** User-initiated disconnect — don't reconnect. |
| 293 | `:1392` `let self, !isCancelled, !intentionalDisconnect` | **[BENIGN]** Same. |
| 294 | `:1404` `try? await Task.sleep(backoff)` | **[BENIGN]** Reconnect backoff; cancellation. |
| 295 | `:1405` `let self, !isCancelled, !intentionalDisconnect` | **[BENIGN]** Same. |
| 296 | `:466` `guard let self` | **[BENIGN]** Teardown. |
| 297 | `:510` `try? await Task.sleep(5s)` | **[BENIGN]** Cancellation. |
| 298 | `:511` `!Task.isCancelled, let self` | **[BENIGN]** Teardown. |
| 299 | `:538` `try? await Task.sleep(authTimeout)` | **[BENIGN]** Cancellation. The auth-timeout path itself **does** report (`lastDisconnectReason`). |
| 300 | `:539` `!Task.isCancelled, let self` | **[BENIGN]** Teardown. |
| 301 | `:579` `let first = urls.first` | **[BENIGN]** Empty URL list. |
| 302 | `:599` `!connectURLs.isEmpty, currentURLIndex != 0` | **[BENIGN]** Already on the primary. |
| 303 | `:657` `backgroundTaskId == .invalid` | **[BENIGN]** Idempotent begin. |
| 304 | `:681` `let task = webSocketTask` | **[BENIGN]** No socket. |
| 305 | `:685` `guard let self, !Task.isCancelled` | **[BENIGN]** Teardown. |
| 306 | `:701` `try? await Task.sleep(timeout)` | **[BENIGN]** Cancellation. |
| 307 | `:712` `backgroundTaskId != .invalid` | **[BENIGN]** Idempotent end. |
| 310 | `:867` `let task = webSocketTask` | **[BENIGN]** No socket. |
| 312 | `:880` `let task = webSocketTask` | **[BENIGN]** No socket. |
| 314 | `:891` `let url = serverURL` | **[BENIGN]** Not configured. |
| 315 | `:939` `try? await Task.sleep(connectTimeout)` | **[BENIGN]** Cancellation; the connect-timeout path reports. |
| 316 | `:940` `let self, !Task.isCancelled` | **[BENIGN]** Teardown. |
| 317 | `:954` `guard let self` | **[BENIGN]** Teardown. |
| 318 | `:999` `let task = webSocketTask` | **[BENIGN]** No socket. |

> Note: the wire-message decode path in this file is **already** loud —
> `WebSocketClient.decodeMessage` is an existing injectable-log loud-drop helper.
> The new store helpers reuse its shape rather than inventing a second convention.

### QuipiOS/Services/WhisperAudioSender.swift (3)

| Line | Site | Class |
|---|---|---|
| 319 | `:30` `guard let resampled = convert(buffer) else return` | **[FIX]** **Every dropped buffer is speech the Mac will never transcribe.** Now latch-logged with a per-session dropped-buffer count. |
| 320 | `:56` `guard let converter else return nil` | **[FIX]** `AVAudioConverter` init failure → *no audio at all* reaches the Mac. Now logged. |
| 321 | `:61` `guard let out = AVAudioPCMBuffer(...) else return nil` | **[FIX]** Output-buffer alloc failure. Now logged. |

*(Also fixed in the same commit, though not in the grep set because it is an `if`
rather than a `guard`: `:74` `if status == .error || error != nil { return nil }` —
where the `NSError` was literally captured and discarded. It is the root of 319–321.)*

### QuipiOS/Views/ConnectionStatusBar.swift (1)

| Line | Site | Class |
|---|---|---|
| 322 | `:90` `!manualIP.isEmpty` | **[BENIGN]** Form validation. |

### QuipiOS/Views/ContentShareReviewSheet.swift (1)

| Line | Site | Class |
|---|---|---|
| 323 | `:41` `let id = selectedWindowId else nil` | **[BENIGN]** No window selected. |

### QuipiOS/Views/QAPairLayoutView.swift (2)

| Line | Site | Class |
|---|---|---|
| 324 | `:219` `abs(dx) >= 40, abs(dx) >= abs(dy)*2` | **[BENIGN]** Swipe-gesture threshold. |
| 325 | `:248` `!draftText.isEmpty, !selectedIsReadOnly` | **[BENIGN]** Sim is read-only in QA v1 — by design. |

### QuipiOS/Views/TTSNotificationOverlay.swift (4)

| Line | Site | Class |
|---|---|---|
| 326 | `:105` `signatures.contains(...) else nil` | **[BENIGN]** No TTS signature match — ordinary. |
| 327 | `:113` `try? NSRegularExpression(pattern:)` | **[BENIGN]** Compile-time-constant pattern. |
| 328 | `:130` `try? NSRegularExpression(pattern: p)` | **[BENIGN]** Same. |
| 329 | `:15` `let wid = currentSpeakingWindowId else nil` | **[BENIGN]** Nothing speaking. |

<!-- END verbatim reproduction -->

---

# PART 3 — STILL OPEN (both peers): 18 real swallows

Deliberately not fixed. **No code was written for any of these.** A follow-up decides.

## QuipMac (10)

| # | Site | Reason left open / risk |
|---|---|---|
| 1 | `WindowManager.swift:352` | **Genuinely risky.** A failed AX call aborts `focusWindow` with zero output, while `moveWindow:418` logs the identical failure. A revoked Accessibility grant (which this repo loses on every Mac rebuild) makes focus silently do nothing. Not fixed only because the sweep was interrupted — this is the one to fix first. |
| 2 | `AuditLogger.swift:58` | **Genuinely risky.** A security-relevant audit entry is dropped with no fallback and no trace when the file handle won't open. An audit log that silently stops auditing is worse than no audit log. |
| 3 | `PromptLibrary.swift:344` | A failed `open(O_EVTONLY)` silently un-starts the prompts FS-watcher; prompt edits stop reaching paired phones with no breadcrumb. |
| 4 | `PromptLibrary.swift:81` | `put()` returns nil on a rejected id but both call sites discard it with `_ =` and dismiss the sheet — a failed save looks like a successful one. Correct fix is a UX decision (surface the rejection), not a log line. |
| 5 | `SwrmProjectStore.swift:46` | Corrupt blob silently forgets every configured swrm project root. Blast radius is one feature; the writer already logs. |
| 6 | `SwrmEventTailer.swift:276` | Corrupt cursor silently resets to `.zero` → full event replay. Self-healing but noisy; low user impact. |
| 7 | `CloudflareTunnel.swift:213` | Failed log-dir `mkdir` → cloudflared's `--logfile` never appears → URL never resolves → watchdog restart loop with no root-cause line. |
| 8 | `WebSocketServer.swift:587` | Unicast dropped for a missing/unauthenticated client, silently. Adjacent backpressure drop at `:588` is equally silent (outside the grep set). |
| 9 | `QuipMacApp.swift:817` | TTS trigger dropped when the window id no longer resolves; the sibling path at `:762` reschedules instead. |
| 10 | `QuipMacApp.swift:839` | `waitForStableContent` nil = a window read that failed for the whole 2.5 s deadline. TTS silently doesn't speak. |

## QuipiOS (8)

| # | Site | Reason left open |
|---|---|---|
| 11 | `BackendSession:61` | QA-pair restore decode — symptom immediately visible, recovery is one long-press. |
| 12 | `BackendSession:71` | Same, persist side. |
| 13 | `QuipApp:4697` | Prompt-MRU decode — degrades to alphabetical sort. Cosmetic. |
| 14 | `QuipApp:4715` | Same. |
| 15 | `QuipApp:4724` | Prompt-MRU encode — a usage timestamp goes unrecorded. |
| 16 | `BackendConnectionManager:496` | Paired-backend cap. Correct fix is a UX decision ("unpin a Mac first"), not a log. |
| 17 | `BackendConnectionManager:567` | Same; `addPaired` returns nil, `applyPairingPayload` skips the PIN write + `setActive` but still calls `doConnect()`. |
| 18 | `SpeechService:792` | Unavailable recognizer → no caption task. Captions are supplementary; site sits inside the protected PTT path. |

---

# Follow-ups recommended (NOT done here)

1. **`WindowManager.swift:352`** (Mac) — log the AX failure the way `moveWindow` already
   does. Highest value / lowest risk item on this list.
2. **`AuditLogger.swift:58`** (Mac) — mirror `QuipLog`'s `createFile` fallback, and make
   a dropped audit entry loud.
3. **`BackendConnectionManager:496/567`** (iOS) — paired-backend cap needs a UX decision,
   not a log line.
4. **`BonjourBrowser`** (iOS) — check whether `netServiceBrowser(_:didNotSearch:)` is
   implemented. A browse that fails to *start* is an absence, not a swallow, so it was
   outside this grep's reach.
5. **`QuickSlotStore.encode` / `CustomButtonStore.encode`** (iOS) — still return `"[]"` on
   failure, which persists an empty row over live data. The wipe is now *audible* but not
   *prevented*; callers assign directly into `@AppStorage`, so making the signature
   optional would ripple.
6. **The grep's blind spot, both peers** — this sweep only sees `try?`,
   `else { return }` and `else { return nil }`. Bare `catch {}`, `if let … {}` with no
   `else`, and ignored return values (e.g. `_ = fm.createFile(...)` right below
   `CloudflareTunnel:213`) are *not* covered. Two of the 17 Mac fixes were `catch` blocks
   found only because they sat next to an enumerated site. A second pass with
   `catch \{\s*\}` and `_ = ` patterns would be a different, non-overlapping sweep.
