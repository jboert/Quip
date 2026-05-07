# Latency-Driven Load Balancing — Auto-Pick Fastest Backend

**Date:** 2026-05-06
**Scope:** Smart-Signal Phase 3. Builds on Phase 1 (`863ee28` — Mac side `send_text` injectMs/totalMs in latency.log) and Phase 2 (unstaged WIP at session end — round-trip ack pipeline + iOS `LatencySample` rolling buffer + `handleSendTextAck`). Phase 3 adds the missing dimensions (backend identity, transport class, signal context) and uses the resulting per-bucket rolling averages to **route each outbound message through whichever backend is currently fastest**.

## Problem

Quip phones can be paired to multiple Mac backends simultaneously (`BackendConnectionManager` keeps each one warm). Today, message routing follows whichever backend the user last selected — there is no consideration of *current* path quality. Real failure modes:

1. **Tunnel slow, LAN fine** — phone roams off home Wi-Fi onto cellular; the local `ws://` path is unreachable but the user is still pinned to it. Or the user is on Wi-Fi but Cloudflare's edge is having a bad night and tunnel RTT spikes to 800ms while the LAN socket is idle.
2. **One Mac slow, the other fine** — the selected Mac is doing something CPU-bound (Whisper download, bulk encode) and `injectMs` is climbing while the other paired Mac is responsive.
3. **Phone signal degraded** — weak Wi-Fi or weak cell, `netRtt` jitter spikes. User experiences sluggish PTT and assumes "Quip is slow"; actually the phone-side RF environment is the cause.

Without telemetry that disambiguates **network** vs **Mac** vs **phone-RF**, the phone cannot decide where to send the next message — so it doesn't even try.

## Non-Goals

- **No automatic *backend pairing***. The user still pairs each Mac manually; load balancing only picks *among already-paired* backends.
- **No partial-message splitting**. A `send_text` always goes to one backend end-to-end. We don't shard a transcript across paths.
- **No fallback retries** in this spec. If the chosen backend fails, the existing reconnect/retry layer handles it. Phase 3 is purely about *which* backend gets dispatched.
- **No accurate Wi-Fi RSSI**. iOS hides Wi-Fi signal strength from non-system apps. We use proxies (NWPathMonitor + RTT variance) instead.
- **No iOS-side counter/measurement of cellular RSSI**. CoreTelephony stopped exposing real values years ago. Same proxies apply.
- **No PTT/audio routing**. PTT and `audio_chunks` already follow the same WS as `send_text`; this spec routes the whole WS, not individual message types.

## Approach

Three additive changes layered on the Phase 2 pipeline:

### 1. Per-bucket rolling latency averages

Phase 2 already keeps `latencySamples: [LatencySample]` (cap 100). Phase 3 widens `LatencySample`:

```swift
struct LatencySample: Equatable {
    let timestamp: Date
    let totalRtt: Int
    let injectMs: Int
    let totalMs: Int
    let netRtt: Int
    let path: String          // "pasteText" | "sendText"  (Phase 2)

    // Phase 3 additions:
    let backendId: UUID       // PairedBackend.id — which Mac
    let transport: Transport  // .localWS | .cloudflareTunnel
    let networkClass: NetworkClass  // .wifi | .cellular | .wired | .unknown
    let netVariance: Int      // ms — std-dev of last 10 netRtt for this backend
}
```

`Transport` and `NetworkClass` are decided at sample time:

- `Transport`: inferred from the WebSocket URL of the originating connection. `ws://` + private IP → `.localWS`. `wss://*.trycloudflare.com` → `.cloudflareTunnel`. Anything else → `.unknown` (unused today).
- `NetworkClass`: read off the existing `NWPathMonitor` (`64a8376` already runs one). `path.usesInterfaceType(.wifi)` / `.cellular` / `.wiredEthernet`.

`netVariance` is computed inline as samples land. Used as the **inferred signal proxy** — high variance = weak / lossy path, low variance = stable.

### 2. `BackendScorer` — pick the fastest backend at send time

A new file `QuipiOS/Services/BackendScorer.swift`:

```swift
struct BackendScorer {
    /// Score = lower is better. Returns the chosen backend's UUID, or nil
    /// if no backend has enough samples yet (caller falls back to the
    /// user-selected backend).
    static func pick(
        from candidates: [BackendConnectionManager.Connection],
        samples: [LatencySample],
        now: Date = Date()
    ) -> UUID?
}
```

Scoring rule (simplest version that handles the documented failure modes):

```
For each candidate that is .authenticated and has ≥3 samples in the last 60s:
    avgNetRtt = mean(netRtt over last 10 samples)
    avgVariance = mean(netVariance over last 10 samples)
    score = avgNetRtt + 0.5 * avgVariance
Pick min-score. Tiebreak: most-recent sample wins (favors warm path).
```

If no candidate has enough samples, return `nil` — caller keeps using the user-picked backend until the scorer warms up. **No silent fallback that changes user's selection without samples to justify it.**

### 3. Route hook in `BackendConnectionManager.send`

Today `send` dispatches to the user-selected backend. After Phase 3:

```swift
func send<T: Codable>(_ message: T) {
    let chosen = BackendScorer.pick(from: connections,
                                    samples: aggregatedLatencySamples)
                 ?? userSelectedBackendId
    connections[chosen]?.client.send(message)
}
```

`aggregatedLatencySamples` is a flat view of every `WebSocketClient.latencySamples` (the rolling buffers already exist per-connection in Phase 2; this just unions them).

## Risks & Open Questions

1. **Cold start.** First few sends after relaunch have no samples → falls through to user-selected backend. Acceptable. (Could pre-warm with a `ping` exchange but that's its own spec.)
2. **Score flapping.** If two backends have similar scores, the per-message decision could oscillate, splitting context across Macs. Mitigation: 100ms hysteresis — once a backend is picked, don't switch unless the alternative is at least 30% faster *and* has at least 2 more recent samples. Add to scoring rule before shipping.
3. **Asymmetric backends.** A backend with no Phase-1 instrumentation (older Mac build) emits no acks → no samples → never picked. Want to either (a) treat ack-less backends as having `score = lastObservedTotalRtt + tax`, or (b) hide them from scoring and only consider for fallback. Defer until first ack-less backend shows up in the wild.
4. **Privacy / log volume.** Latency.log on Mac already records per-message timing. `[Quip][LATENCY]` NSLog from Phase 2 is on iOS. Adding `transport=cloudflareTunnel networkClass=cellular` per sample is fine for triage but should NOT be exported in any user-facing share without redacting `backendId` (UUID is internal but still an identifier).
5. **Cellular cost.** Auto-routing to cellular when LAN is slow could surprise users who don't want Quip on their data plan. Settings toggle: "Allow cellular routing when faster than LAN" — default ON (matches user-stated goal: "always load balance to best signal"), but discoverable.

## Test Plan

- **`BackendScorerTests`:** seed `LatencySample` arrays for 1, 2, 3 candidate backends across mixed transport/network class buckets. Assert (a) lowest-score backend is picked, (b) cold-start returns nil, (c) tiebreak picks most-recent, (d) hysteresis prevents flap when scores are within 30%.
- **`LatencySampleTaggingTests`:** verify each sample is tagged with the correct `transport` derived from URL pattern + `networkClass` from a stubbed `NWPath`.
- **`BackendConnectionManagerRoutingTests`:** stub two connections, push synthetic samples that make backend B faster, assert `send` lands on B's WebSocketClient.

Hardware verification (post-merge):
- Pair two Macs to one phone. Throttle Cloudflare tunnel via Network Link Conditioner. Send PTT transcript. Verify `[Quip][LATENCY]` log shows path=local picked when LAN faster, path=tunnel picked when LAN unreachable.
- Roam phone from Wi-Fi to cellular mid-session. Verify `networkClass` flips in next sample and scorer re-picks.

## Sequencing

1. **Block on Phase 2 commit.** Three files unstaged in working tree at end of cont-7 (`Shared/MessageProtocol.swift`, `QuipMac/QuipMacApp.swift`, `QuipiOS/Services/WebSocketClient.swift`). Phase 3 widens `LatencySample` and hooks `BackendConnectionManager.send` — both touch the same files. Don't fork.
2. **Land widening + tagging first** (commit 1). `LatencySample` schema + per-sample `transport`/`networkClass` derivation + tests. No routing change yet — purely observational.
3. **Land scorer + routing** (commit 2). `BackendScorer.pick` + hook in `BackendConnectionManager.send` + tests + Settings toggle for cellular routing.
4. **Hardware verify** with Network Link Conditioner before declaring done. Add findings + the "ack-less backend" decision (open question 3) back to wishlist.

## Related

- Phase 1: `863ee28` Mac instrument send_text → latency.log
- Phase 2: WIP unstaged in cont-7 working tree (LatencySample, send_text_ack, handleSendTextAck)
- `64a8376` NWPathMonitor on iOS — already running; reused here for `networkClass`
- `project_multibackend_wire_bridge.md` — every new BackendConnectionManager hook needs a `c.onFoo` bridge in `wire()`. Phase 3 doesn't add new callbacks; the routing hook is in `send`, not a callback. **No wire() change required** — flag this for the reviewer anyway.
- Wishlist §30 thread #2 (DisconnectReason) shipped in cont-6 (`9f382ef`); Phase 3 layers per-backend telemetry on top so a `.networkError` disconnect can also annotate which backend it was on.
