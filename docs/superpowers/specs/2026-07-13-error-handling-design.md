# Error handling — design

**Date:** 2026-07-13
**Peers:** QuipMac + QuipiOS only. QuipLinux / QuipAndroid are out of scope.
**Status:** approved, ready for implementation plan

## Why

Three failures today came from Quip's error reporting, not from Quip's logic:

1. `websocket.log` printed `Connection FAILED: POSIXErrorCode(rawValue: 54): Connection reset by peer` once a minute. Those were `LatencyProbeService` TCP probes closing normally. Acting on that line, the investigation chased a dual-backend deadlock that did not exist and nearly shipped a two-peer networking change to fix a bug that was never there.
2. `Connection ready (pending auth)` prints even when `requireAuth` is false and the client is already authenticated. The log states a condition the code is not in.
3. A photo upload was reported as broken. The Mac had acked both attempts, and Codex had in fact read the image. The real problem was a Codex `npm i` update with no visible progress. Nothing in Quip's output made it possible to tell "delivered" from "not delivered" without reading the Codex pane directly.

The common thread: benign events look like failures, failures look like nothing, and successes are claimed without evidence. That costs debugging hours and, worse, invites fixes to non-existent bugs.

## Scope

Approved: (a) logs that lie, (b) phone-facing failures, (c) swallowed-errors sweep.

Explicitly NOT in this spec, deferred to the wishlist:
- `pasteImage` hard-fails on Terminal.app and the caller never implements the fallback its own comment promises (`KeystrokeInjector.swift:350`, caller `QuipMacApp.swift:1393`).
- Image paste puts only `public.tiff` on the clipboard — no PNG/JPEG, no file URL.

## 1. The facility

One reporting path, so the fixes below do not each invent a `print`.

`QuipLog` — severity (`info` / `warn` / `error`) plus a subsystem tag, written to the existing `~/Library/Logs/Quip/*.log` files through `LogPaths`. A reader must be able to separate "benign thing happened" from "something broke" at a glance. That is the whole requirement; anything beyond it is out of scope.

## 2. Logs that lie

Each item below misled a real investigation today.

| Problem | Fix |
| --- | --- |
| Latency probes log as `Connection FAILED` (`WebSocketServer.swift`, the `newConnectionHandler` / state-change path) | Classify a connection that closes **before completing the WS handshake** as an aborted handshake / probe. Log at `info`. Reserve `error` for a socket that failed *after* it went `ready`. |
| `Connection ready (pending auth)` prints when no auth is required (`WebSocketServer.swift:~364`) | Log the state the code is actually in: `awaiting PIN` vs `authenticated (no PIN required)`. |
| No line marks a client going live | Add one, so success is greppable and not merely the absence of noise. |
| `image_upload: delivered` (`QuipMacApp.swift:1429`) | It means "AppleScript returned no error". We do not know the target app consumed the image. Say `injected`, and keep the honest limit in the diagnostic line. |

The probe-vs-real decision must be a **pure function** over (handshake completed?, close reason) so it is unit-testable without a socket.

## 3. Never spin forever (phone)

Contract: **every in-flight action has a deadline.** On timeout or error it resolves to a failed state carrying a cause and one next step ("Mac didn't confirm the paste — tap to retry"). No indefinite spinners anywhere.

`PendingImageState.debugStage` (10s watchdog, breadcrumbs `encoding-start` / `encoded NB` / `sending b64=NB` / `sent, awaiting ack`) is the existing template. Generalize that shape to the other in-flight actions: send text, keystroke, dictation, prompt tap.

Out of scope by explicit decision: inline retry affordances and a phone-side diagnostics panel. Deadline + clear failed state only.

## 4. The triage sweep

Surface, measured (excluding tests):

| | QuipMac | QuipiOS |
| --- | --- | --- |
| `try?` | 81 | 68 |
| `else { return }` | 98 | 226 |
| `else { return nil }` | 41 | 27 |
| empty `catch` | 0 | 0 |

~540 sites. **Most are legitimate control flow, not swallowed errors** — a `guard let` on an optional, an early return on an empty list. Blanket-logging all of them would bury the real signals under new noise, which is the disease being cured.

Method:
1. Enumerate every site mechanically.
2. Classify each: **real swallow** (an error value or failure path is discarded) or **benign control flow**.
3. Fix every real swallow using the facility from §1.
4. Write the accounting: what was classified benign and why, so "we covered everything" is verifiable rather than asserted. Silent truncation of the list is a failure of this spec.

## Testing

Logic lives in pure functions so it is testable without hardware in the loop:
- probe-vs-real connection classification
- log severity / formatting
- the phone's deadline state machine (in-flight → timeout → failed-with-cause)

Plus a regression test per fixed swallow where the failure is reproducible.

Mac test runs: signed, with Quip quit first (the test host binds 8765). Skip `APNsJWTTests` — it blocks the whole suite on a Keychain authorization prompt (`APNsKeyStore.get()`, `APNsKeyStore.swift:62`), observed hanging 57 minutes today. That is a separate bug, tracked on the wishlist.

## Sequencing

1. Facility (§1)
2. Logs that lie (§2) — small, surgical, highest debugging value
3. Never spin forever (§3)
4. Triage sweep (§4) — large; most of the effort is the classification pass

Stages 2 and 3 are independently shippable. Stage 4 is the long tail; the work can stop after any stage with value already banked.
