# Mobile "Use Local Network" switch — design

**Date:** 2026-06-30
**Branch:** eb-branch
**Status:** approved, implementing

## Context

On the iPhone app there is no way to deliberately connect over the local network
(LAN) once a backend is already connected, and the Bonjour "Local" discovery
tiles often appear blank. Two concrete user-visible gaps were confirmed in code:

1. **Can't switch once connected.** The Connect Bar (which hosts the Bonjour
   tiles) is only shown while fully disconnected — `QuipApp.swift:1420`
   (`if !client.isConnected && !client.isConnecting`). Once any path connects,
   it is replaced by the connected bar. `BackendPickerSheet` shows only the
   primary URL read-only; `PairedBackend.fallbackURLs` are never exposed and the
   latency hot-swap (`BackendConnectionManager.performHotSwap`) is private /
   automatic. There is no manual "use LAN now" control anywhere.

2. **Tiles silently empty.** `BonjourBrowser` uses legacy `NetServiceBrowser`,
   never handles iOS Local Network permission denial, and the UI only renders
   tiles when hosts exist — no "permission denied / none found" feedback.

Root cause of "stuck on Tailscale": a phone paired only over Tailscale
(cellular/remote) has **no LAN fallback URL stored at all**. `mergedURLOrder`
deliberately keeps Tailscale primary (stable while roaming); LAN is meant to be
a fast fallback — but if the LAN URL was never learned, there's nothing to fall
back to and nothing to switch to. The only way to learn the Mac's LAN address is
Bonjour, which is disconnected-only and permission-gated.

**Outcome:** an explicit, reliable "Use Local Network" control on the phone that
works even when the phone only ever paired over Tailscale, plus feedback when
Bonjour discovery is blocked.

## Approach (approved)

### Enabler — the Mac reports its LAN address in the identity handshake

`DeviceIdentityMessage` (`Shared/MessageProtocol.swift:1162`) is sent Mac→phone
right after auth. Add an optional field carrying ready-to-use LAN WebSocket URLs:

```swift
let localURLs: [String]?   // e.g. ["ws://192.168.1.50:8765"]; nil from peers that don't supply it
```

- Codable, `decodeIfPresent` → nil default; init param defaults to nil so the
  iOS self-identity send (`WebSocketClient.swift:740`) and Rust/Linux sender are
  unaffected (back-compatible both directions).
- Mac enumerates its private IPv4 interfaces via `getifaddrs` (RFC1918 only,
  skip loopback/link-local), formats `ws://<ip>:8765` (the WS server binds a
  fixed `0.0.0.0:8765`), and passes them into both identity sends
  (`WebSocketServer.swift:372` no-PIN path and `:823` PIN path).
- **Mac-only for now.** The Rust/Linux daemon is out of scope (separate lane);
  Linux backends simply won't offer the LAN switch.

### iOS — ingest the LAN URLs

In the live `device_identity` handler (the `c.onDeviceIdentity` closure in
`BackendConnectionManager.wire`, ~line 1033 — note `recordDeviceIdentity` is dead
code, no callers), at the **top** of the closure merge `identity.localURLs` into
the row matching `session.backendID` before the rekey/merge branches run:

```swift
ingestLocalURLs(identity.localURLs ?? [], into: session.backendID)
```

`ingestLocalURLs` dedups, re-sorts with the existing `mergedURLOrder`
(Tailscale-first, so the live primary is never disrupted — LAN lands as a
fallback), updates `paired[i].url`/`fallbackURLs`, and `savePaired()`. It does
**not** reconnect — fallback URLs are only consumed on the next reconnect, and
the manual switch (below) triggers that explicitly. Placing the call before the
branches means the rekey path (carries URLs when the row id is rebuilt) and the
same-Mac merge path (unions both rows' URLs) both pick the LAN URLs up for free.

### iOS — the manual switch

New public method on `BackendConnectionManager`:

```swift
func switchToLANPath(_ id: String)
```

Mirrors `performHotSwap`: find the first LAN-class URL in `urlsInOrder`, reorder
it to index 0, `disconnect()` → `connect(toURLs:)`. Because index 0 becomes the
LAN URL, `resetToPrimaryURL()` (fired by the path monitor on Wi-Fi changes) keeps
LAN rather than reverting to Tailscale — LAN stays pinned for the session.
`lastSwapAt = Date()` suppresses the auto-evaluator from immediately fighting it.
Order is in-memory only (no `savePaired`), so a relaunch returns to the saved
Tailscale-first order — swaps are tactical, matching the existing hot-swap
contract.

Pure, testable helpers (static, on `BackendConnectionManager`, reusing
`urlPriority`):

- `static func isLANURL(_ url: URL) -> Bool` → `urlPriority <= 1` (.local + RFC1918)
- `static func pathLabel(for url: URL?) -> String` → "Local network" / "Tailscale" / "Remote" / "—"

### iOS — the tile (`BackendPickerSheet`)

For the **active** backend row, when `isLANURL` exists in `urlsInOrder` and the
session's current `serverURL` is not already LAN, show a compact inline control:
current path label + a "Use Local Network" button (wifi icon) calling
`manager.switchToLANPath(id)`. Honors the compact-UI rule — one small row, no new
screen.

### iOS — permission hint (`connectBar`)

Add a grace flag to `BonjourBrowser` (`graceElapsed`, set false on
`startBrowsing`, flipped true ~4s later). In the Connect Bar, when disconnected
and `discoveredHosts.isEmpty && graceElapsed`, show an informational tile:
"No Macs found on Wi-Fi — Local Network access may be off →" deep-linking to
`UIApplication.openSettingsURLString`. (iOS exposes no clean LN-permission read;
this is a heuristic hint, not a hard status.)

## Files

- `Shared/MessageProtocol.swift` — `localURLs` field on `DeviceIdentityMessage`
- `QuipMac/Services/WebSocketServer.swift` — interface enumeration + populate both sends
- `QuipiOS/Services/BackendConnectionManager.swift` — `ingestLocalURLs`, `switchToLANPath`, `isLANURL`, `pathLabel`
- `QuipiOS/Services/BonjourBrowser.swift` — `graceElapsed` flag
- `QuipiOS/Views/BackendPickerSheet.swift` — LAN switch tile
- `QuipiOS/QuipApp.swift` — connectBar permission hint
- Tests: `QuipiOSTests/Tests/BackendConnectionManagerURLMergeTests.swift` (ingest + helpers), `BackendPickerStatusTests.swift` (tile visibility logic)

## Verification

- TDD the pure logic first: `isLANURL`, `pathLabel`, `ingestLocalURLs` ordering
  (LAN stays fallback after ingest), tile-visibility predicate.
- `xcodebuild` iOS test target (Swift 6 is the only reliable isolation oracle).
- `xcodebuild` Mac target — `getifaddrs` enumeration compiles; build with
  `CODE_SIGNING_ALLOWED=NO` for tests.
- Manual: on the QA simulator / device, pair over Tailscale, confirm the picker
  shows "Use Local Network" once the Mac's identity carries `localURLs`; tap it,
  confirm `serverURL` flips to the LAN IP. Toggle Local Network permission off,
  confirm the connectBar hint appears.

## Caveat

Touches `QuipMac/` → a Mac rebuild, which per project rule wipes Screen Recording
+ Accessibility TCC grants and needs re-granting. Unavoidable: the Mac must
report its LAN IP for the feature to work. User accepted this cost.
