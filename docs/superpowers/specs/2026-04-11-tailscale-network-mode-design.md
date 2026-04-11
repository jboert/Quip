# Tailscale Network Mode — Design

**Date:** 2026-04-11
**Status:** Approved, awaiting implementation plan

## Problem

Quip's phone-to-Mac connection currently relies on a Cloudflare quick tunnel (`*.trycloudflare.com`). The URL rotates every time cloudflared restarts, so the user has to re-scan the QR code or re-paste the URL on the phone after each Mac app restart. The alternative "Local only" mode only works when both devices are on the same LAN — useless when away from home.

The user wants a third option: a stable remote connection that's free and doesn't require owning a domain. **Tailscale** fits — its MagicDNS hostnames (`foo.tail1234.ts.net`) and CGNAT IPs (`100.64.0.0/10`) are stable for the lifetime of the node, and the free tier covers personal use.

## Non-goals

- No Cloudflare Named Tunnel support (requires owning a domain).
- No WireGuard self-hosting.
- No automatic installation of Tailscale — user installs and logs in on both devices themselves.
- No HTTPS cert provisioning (MagicDNS HTTPS requires the user to enable it on their tailnet; out of scope).
- No Swift unit tests — repo has no test scaffolding today and adding it is out of scope.

## User experience

1. User opens Quip's **Settings → Connection** tab.
2. A **Network Mode** picker offers three mutually exclusive options: `Cloudflare Tunnel` (default), `Tailscale`, `Local only`.
3. When `Tailscale` is selected:
   - The app detects the Mac's Tailscale hostname automatically.
   - The Connection tab shows the detected hostname (read-only) and an optional override text field.
   - The MainWindow status bar and QR popover display `ws://<hostname>:<port>`.
   - Cloudflared is not launched.
4. The phone connects to that URL. Because `*.ts.net` and `100.64.x.x` are on the trust whitelist, no "Unrecognized Server" warning fires.
5. The URL stays stable across Mac app restarts, phone restarts, network changes, etc. — as long as both devices remain logged into the same Tailscale account.

## Architecture

### New types

- **`NetworkMode` enum** (`QuipMac/Services/NetworkMode.swift`):
  ```swift
  enum NetworkMode: String, CaseIterable, Identifiable {
      case cloudflareTunnel
      case tailscale
      case localOnly
      var id: String { rawValue }
  }
  ```
  Persisted as `@AppStorage("networkMode")`.

- **`TailscaleService` class** (`QuipMac/Services/TailscaleService.swift`):
  ```swift
  @MainActor @Observable
  final class TailscaleService {
      var hostname: String = ""
      var webSocketURL: String = ""
      var isAvailable: Bool = false
      var lastError: String? = nil

      func refresh()   // one-shot CLI detection
      func stop()      // clears published state
  }
  ```
  Follows the existing service pattern (see `BonjourAdvertiser`, `CloudflareTunnel`). Reads `@AppStorage("tailscaleHostnameOverride")` internally for the override path.

### Migration

First time `applyNetworkMode()` runs after the update:
- If `@AppStorage("networkMode")` is unset:
  - Read legacy `@AppStorage("localOnlyMode")`.
  - If true → set `networkMode = .localOnly`.
  - Else → set `networkMode = .cloudflareTunnel`.
- Legacy `localOnlyMode` key is never written again.

### Wiring in `QuipMacApp.swift`

- Create a `TailscaleService` instance alongside the existing `CloudflareTunnel`, inject into the environment.
- New helper `applyNetworkMode()` switches on `networkMode`:
  - `.cloudflareTunnel` → `tunnel.start()`, `tailscale.stop()`
  - `.tailscale` → `tunnel.stop()`, `tailscale.refresh()`
  - `.localOnly` → `tunnel.stop()`, `tailscale.stop()`
- Called on app launch and on `onChange(of: networkMode)`.
- Also called on `NSApplication.didBecomeActiveNotification` — cheap and catches the "user opened Tailscale mid-session" case.

### Detection logic (`TailscaleService.refresh()`)

1. **Manual override short-circuit.** If `tailscaleHostnameOverride` is non-empty, use it verbatim, set `isAvailable = true`, skip the CLI.
2. **Locate the CLI** in order:
   1. `/usr/local/bin/tailscale`
   2. `/opt/homebrew/bin/tailscale`
   3. `/Applications/Tailscale.app/Contents/MacOS/Tailscale`
   
   First one that exists and is executable wins. None found → `lastError = "Tailscale not installed"`, `isAvailable = false`.
3. **Shell out to `tailscale status --json`** on a background queue (never blocks main). 3-second timeout. Non-zero exit or timeout → `lastError = "Tailscale not running or not logged in"`, `isAvailable = false`.
4. **Parse JSON** — extract `Self.DNSName` (MagicDNS name, e.g. `quip-mac.tail1234.ts.net.`). Strip trailing dot. If empty, fall back to `Self.TailscaleIPs[0]` (100.x address). Both empty → `lastError = "No Tailscale identity"`, `isAvailable = false`.
5. **Build WebSocket URL** using the existing `@AppStorage("wsPort")` value: `ws://<host>:<port>`. Plain `ws://` — traffic is encrypted by Tailscale itself; HTTPS certs on MagicDNS would require the user to enable them on their tailnet (separate feature).
6. **Publish** on the main actor: assign `hostname`, `webSocketURL`, `isAvailable = true`, `lastError = nil`.

`refresh()` is idempotent — calling it while a previous run is in flight cancels and restarts.

`stop()` zeroes `hostname`/`webSocketURL`/`isAvailable` so the UI doesn't show stale data after a mode change.

## UI changes

### `QuipMac/Views/SettingsView.swift → ConnectionTab`

Replace the existing `localOnlyMode` toggle with a `Picker("Network Mode", selection: $networkMode)` offering the three `NetworkMode` cases.

Below the picker, a conditional subview rendered only when `networkMode == .tailscale`:
- `LabeledContent("Hostname")` showing `tailscale.hostname` (or "Not detected" in red if empty).
- `Button("Re-detect")` calling `tailscale.refresh()`.
- `TextField("Hostname override (optional)")` bound to `@AppStorage("tailscaleHostnameOverride")`. Empty = auto. Changing triggers `tailscale.refresh()`.
- If `tailscale.lastError != nil`, caption underneath shows it.

Explanatory caption under the picker adapts per mode:
- `.cloudflareTunnel` → current text ("Cloudflare tunnel enables connections from anywhere…").
- `.tailscale` → "Both devices must be on your Tailscale network. The URL stays stable across restarts."
- `.localOnly` → existing local-only text.

`requirePINForLocal` toggle is unchanged — PIN enforcement is orthogonal to network mode.

### `QuipMac/Views/MainWindow.swift`

`tunnelQRPopover` and `tunnelStatus` currently branch on `localOnlyMode`. Change both to read `networkMode`:

- `.cloudflareTunnel` → `tunnel.webSocketURL` (existing behavior).
- `.tailscale` → `tailscale.webSocketURL`, with loading state when `isAvailable == false` and `lastError == nil`, or error state when `lastError != nil`.
- `.localOnly` → `localWSURL` (existing).

Status bar icons:
- Cloudflare: existing `globe` green.
- Tailscale: new `network` or `link.circle` icon in blue.
- Local: existing `house` blue.

### `QuipiOS/QuipApp.swift → isURLTrusted(_:)`

Add to the `ws://` branch, alongside the existing LAN private-IP checks:

```swift
// Tailscale MagicDNS
if host.hasSuffix(".ts.net") { return true }

// Tailscale CGNAT 100.64.0.0/10
if parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1]) { return true }
```

Both apply to `ws://` only. Trust rationale: `.ts.net` is a Tailscale-controlled suffix only resolvable inside the user's tailnet; `100.64.0.0/10` is CGNAT used exclusively by Tailscale — reaching either means the phone is already on the tailnet.

### `QuipiOS/QuipApp.swift → doConnect()` URL normalization

Add one branch: if the raw input ends with `.ts.net` or matches `100.x.x.x`, default the scheme to `ws://` (not `wss://`). So the user can paste a bare hostname from the Mac without typing the scheme.

## Data flow

```
User toggles picker to Tailscale
  → @AppStorage("networkMode") = .tailscale
  → onChange fires in QuipMacApp
  → applyNetworkMode() called
  → tunnel.stop()
  → tailscale.refresh()
    → [background] locate CLI, run `tailscale status --json`, parse
    → [main] assign hostname, webSocketURL, isAvailable
  → MainWindow status bar and QR popover observe tailscale fields, redraw
  → User scans QR on phone
  → Phone connects to ws://<hostname>:<port>
  → isURLTrusted returns true (.ts.net or 100.x)
  → WebSocketClient.connect succeeds, PIN auth proceeds as normal
```

## Error handling

| Failure | Behavior |
|---|---|
| Tailscale not installed | Red caption "Tailscale not installed — install from tailscale.com" in ConnectionTab, red indicator in MainWindow status bar, error message in QR popover. |
| Daemon not running / not logged in | Same UI pattern, caption reads "Tailscale not running or not logged in". |
| `tailscale status` returns empty DNSName and empty TailscaleIPs | "No Tailscale identity" — usually a mid-login state. |
| User opens Tailscale mid-session | `refresh()` fires on `didBecomeActiveNotification`. Manual Re-detect button as fallback. |
| User sets invalid override hostname | No validation — existing 8s WebSocket connect timeout on phone handles it. |
| Phone not on tailnet when scanning | Existing 8s connect timeout → existing "Connection timed out" error. No special message. |
| Phone loses Tailscale route while backgrounded | Existing reconnect-with-backoff in `WebSocketClient.handleDisconnect()` handles it. |
| iOS background `ws://` (no TLS) | Possible issue — ship as-is; if it surfaces, follow up with Tailscale-HTTPS-cert as a separate feature. |

## Testing

No Swift unit tests; manual verification checklist before calling it done:

1. Fresh install (no AppStorage): defaults to Cloudflare Tunnel, cloudflared starts, QR shows trycloudflare URL.
2. Existing user with `localOnlyMode=true`: migrates to Local only, no tunnel starts.
3. Switch to Tailscale with CLI installed + logged in: status bar shows `ws://<magicdns>:<port>`, cloudflared stops, phone connects, PIN auth works.
4. Switch to Tailscale with CLI missing: red error caption, no crash.
5. Override field: typing a value replaces the auto-detected host immediately.
6. Switch back to Cloudflare: tailscale fields clear, cloudflared restarts, new trycloudflare URL appears.
7. Phone re-scans same Tailscale URL after Mac restart — connects without re-entering URL.

## Files touched

- **New:** `QuipMac/Services/NetworkMode.swift`
- **New:** `QuipMac/Services/TailscaleService.swift`
- **Modified:** `QuipMac/QuipMacApp.swift` — instantiate service, `applyNetworkMode()`, migration, activation observer
- **Modified:** `QuipMac/Views/SettingsView.swift` — `ConnectionTab` picker + tailscale subview
- **Modified:** `QuipMac/Views/MainWindow.swift` — three-way branch in `tunnelQRPopover` and `tunnelStatus`
- **Modified:** `QuipiOS/QuipApp.swift` — `isURLTrusted()` additions, `doConnect()` scheme-default tweak
