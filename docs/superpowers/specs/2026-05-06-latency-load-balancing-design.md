# Latency-Driven Load Balancing — Auto-Pick Fastest URL to Same Backend

**Date:** 2026-05-06 (revised after architecture review)
**Scope:** Smart-Signal Phase 3. Builds on Phase 1 (`863ee28` — Mac side `send_text` injectMs/totalMs in latency.log) and Phase 2 (`abb89a9` — round-trip ack pipeline + iOS `LatencySample` rolling buffer + `handleSendTextAck`). Phase 3 adds the missing dimensions (transport class, signal context, per-URL bucket) and uses the resulting per-URL rolling averages to **hot-swap the WebSocket between paths to the SAME backend Mac when a faster path appears**.

## Revision note (2026-05-06)

Original draft proposed routing **across paired backends** (different Macs). Architecture review surfaced a critical mismatch: each paired Mac has its own terminal state — `send_text` to Mac A vs Mac B types into different keyboards. Load-balancing across Macs would land messages on the wrong machine.

User goal restated: "always load balance to the best signal." Common deployment is ONE Mac with multiple paths to it (Bonjour `.local`, RFC1918 LAN, Tailscale CGNAT, Cloudflare tunnel) — captured in `PairedBackend.urlsInOrder`. WebSocketClient currently picks the first URL that succeeds at connect-time and stays on it until disconnect, even when a faster alternative exists.

Phase 3 now targets **across URLs within the active backend's `urlsInOrder`**, not across backends.

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

## Approach (revised)

Four additive changes layered on the Phase 2 pipeline:

### 1. Per-bucket rolling latency averages — SHIPPED in commit 1/2

Phase 3 commit 1 (`49160d5`) widened `LatencySample`:

```swift
struct LatencySample: Equatable {
    let timestamp: Date
    let totalRtt: Int
    let injectMs: Int
    let totalMs: Int
    let netRtt: Int
    let path: String          // "pasteText" | "sendText"  (Phase 2)
    let transport: LatencyTransport       // .localWS | .cloudflareTunnel | .unknown
    let networkClass: LatencyNetworkClass // .wifi | .cellular | .wired | .unknown
    let netVariance: Int       // ms — std-dev of last 10 same-transport samples
}
```

`netVariance` is the iOS-feasible signal-strength proxy (RSSI is hidden from non-system apps). High variance = lossy / weak link; low variance = stable.

### 2. Per-URL sample bucketing (Phase 3 commit 2/3 — NEXT)

Transport class lumps Bonjour LAN and Tailscale CGNAT into the same `.localWS` bucket. For URL hot-swap, samples must be addressable per URL. Add `serverURLHost: String` to `LatencySample` (just the host portion — full URL leaks port noise into the bucket key).

`handleSendTextAck` already has access to `serverURL`; tagging the host is one line.

### 3. `LatencyProbeService` — sample non-current URLs (Phase 3 commit 3/3)

WebSocketClient is connected to ONE URL at a time, so its `latencySamples` only carry data for the active path. To know whether an alternative URL is *currently* faster, run periodic transient probes against the alt URLs:

- Every 60s, for each URL in `paired[active].urlsInOrder` that's NOT the current `serverURL`, open a TCP connection (no WS handshake — too noisy, and not what the alt would look like once promoted), time `connect` to "ready", close.
- Append a synthetic `LatencySample` with `netRtt = TCP-connect ms`, `injectMs = 0`, `totalMs = 0`, `path = "probe"`, the alt URL's host as `serverURLHost`, transport classified from the alt URL, networkClass from the live monitor.
- Cap probe samples at 5 per URL to keep the buffer lean.

Probe samples are mixed into `latencySamples` but flagged via `path == "probe"` so the existing latency-summary UI in `SettingsSheet → Diagnostics` can filter them out of the user-facing medians (they're not real text-land latency).

### 4. `URLSwapPolicy` — decide when to hot-swap

Pure decision function used by `BackendConnectionManager`:

```swift
struct URLSwapPolicy {
    /// Returns the URL to swap to, or nil to stay put.
    static func decide(
        currentURL: URL,
        candidates: [URL],
        samples: [LatencySample],
        lastSwapAt: Date?,
        now: Date = Date()
    ) -> URL?
}
```

Rule:

```
Reject if lastSwapAt < 5 min ago (hysteresis — max one swap per 5 min).
Reject if no candidate has ≥3 fresh samples (last 5 min).

For current URL:    avgNetRtt over last 10 same-host samples (any path, including probe).
For each candidate: avgNetRtt same way.

Pick best candidate where:
    bestAvgNetRtt < currentAvgNetRtt * 0.7
    AND last 3 candidate samples each beat currentAvgNetRtt
Return that URL. Else nil.
```

The 30% threshold is intentionally aggressive — at 10% the probe noise dominates and the phone flaps every 5 minutes; at 50% only catastrophic regressions trigger. 30% is a starting point; revise after one week of latency.log data.

### 5. Swap orchestration in BackendConnectionManager

When `URLSwapPolicy.decide` returns a non-nil URL:

1. Log `[Quip][LATENCY] hot-swap: from=X to=Y reason=avg-30%`.
2. `session.client.disconnect()` (intentional flag set so reconnect logic doesn't fire).
3. Reorder `urlsInOrder` so the chosen URL is first (in-memory only — don't `savePaired()`; the user's preference order is preserved across launches).
4. `connect(toURLs:)` with the reordered list.
5. Stamp `lastSwapAt = Date()` for hysteresis.

The brief disconnect/reconnect produces a sub-second blip in the §K connection pill (`reachability = .connecting → .connected`). User experience: an occasional 1-second yellow flicker that the actual messages following are noticeably faster. Worth surfacing in the Settings → Diagnostics "Latency" detail sheet as a "Last swap: 14m ago" line so the user can correlate.

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

## Sequencing (revised)

1. **Phase 2 commit landed** at `abb89a9` — round-trip ack pipeline + LatencySample buffer in WebSocketClient.
2. **Phase 3 commit 1 landed** at `49160d5` — observational widening with transport / networkClass / netVariance tagging + 14 tests.
3. **Phase 3 commit 2 (next)** — per-URL sample bucketing. Add `serverURLHost: String` to `LatencySample`; tag in `handleSendTextAck`. Tests for the addressing change. No behavior change yet.
4. **Phase 3 commit 3** — `LatencyProbeService` + `URLSwapPolicy` + swap orchestration in `BackendConnectionManager`. Single user-visible Settings row (Latency → "Auto-pick fastest path" toggle, default ON). Tests cover policy decision matrix, probe sample tagging, swap-cooldown hysteresis.
5. **Hardware verify** with Network Link Conditioner before declaring done. Throttle Cloudflare path → verify swap to LAN. Roam from Wi-Fi to cellular → verify networkClass updates and probes resume on alt paths.

## Related

- Phase 1: `863ee28` Mac instrument send_text → latency.log
- Phase 2: WIP unstaged in cont-7 working tree (LatencySample, send_text_ack, handleSendTextAck)
- `64a8376` NWPathMonitor on iOS — already running; reused here for `networkClass`
- `project_multibackend_wire_bridge.md` — every new BackendConnectionManager hook needs a `c.onFoo` bridge in `wire()`. Phase 3 doesn't add new callbacks; the routing hook is in `send`, not a callback. **No wire() change required** — flag this for the reviewer anyway.
- Wishlist §30 thread #2 (DisconnectReason) shipped in cont-6 (`9f382ef`); Phase 3 layers per-backend telemetry on top so a `.networkError` disconnect can also annotate which backend it was on.
