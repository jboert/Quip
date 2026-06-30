# Session handoff — 2026-06-30

## Commits today (eb-branch, NOT pushed)

- `b39217a` feat: manual "Use Local Network" switch on iOS — Mac reports its
  LAN IP in the identity handshake; phone learns it as a fallback and exposes
  a one-tap "Use Local Network" tile in the backend picker, plus a permission
  hint when Bonjour tiles stay blank. Closes the "can't grab faster LAN on
  mobile" gap.

(Also this session, outside this repo: updated `~/.claude/statusline-command.sh`
to show reasoning effort — not part of Quip git.)

## What the feature does (recap)

- **Shared:** `DeviceIdentityMessage.localURLs: [String]?` (back-compat optional).
- **Mac:** `WebSocketServer.localWebSocketURLs()` enumerates RFC1918 interfaces
  via `getifaddrs` → `ws://<ip>:8765`, sent on both identity paths (no-PIN + PIN).
- **iOS:** ingests `localURLs` as Tailscale-first fallbacks (live primary
  untouched); `switchToLANPath(_:)` pins LAN for the session; picker tile +
  `BonjourBrowser.graceElapsed` permission hint.
- Spec: `docs/superpowers/specs/2026-06-30-mobile-local-network-switch-design.md`

## Install state

| Target | Installed | Notes |
|---|---|---|
| Mac `/Applications/Quip.app` | **v1.5.5, built Jun 20** — PREDATES this feature | NOT rebuilt this session. Until rebuilt, the Mac sends NO `localURLs`, so the phone tile never appears. |
| iOS device (primary iPhone 17 Pro Max) | NOT installed this session | New phone code is only in git. |

## Hardware-verified vs install-only matrix

| Item | Status |
|---|---|
| iOS unit tests (LAN classify + ingest ordering) | ✅ verified — 26 green on sim `CFCE8360` (iPhone 17 Pro, iOS 26.5) |
| Mac unit tests (`isPrivateIPv4`) | ✅ verified — 3 green |
| iOS full compile (app links via test target) | ✅ verified (xcodebuild) |
| Mac full compile (`getifaddrs` path) | ✅ verified (xcodebuild) |
| **End-to-end on real Mac + phone** | ❌ NOT done — needs Mac rebuild + iOS install |
| Tile appears after Tailscale-only pairing | ❌ unverified live |
| Permission hint on real LN-denied state | ❌ unverified live (heuristic, no clean iOS API) |

## Open threads

1. **Install pending.** Mac rebuild (resets Screen Recording + Accessibility
   TCC — user pre-accepted) + iOS reinstall + force-quit/relaunch phone. User
   was asked build-now-or-hold; awaiting answer.
2. **Push pending.** Commit `b39217a` + this handoff are local only. Do not push
   without explicit user OK (per eb-branch policy).
3. **Tile timing:** tile only shows after the FIRST connect to a rebuilt Mac
   (that's when `localURLs` first arrives). First post-install connect may still
   be Tailscale.
4. **Stale memory:** `feedback_default_qa_simulator` UDID `3B2ACF04…` no longer
   exists; current sim is `CFCE8360-508E-4A66-B0FD-615D8CD2A549` (iPhone 17 Pro,
   iOS 26.5). Offered to update memory; awaiting answer.
5. **Linux daemon** does NOT send `localURLs` (Jakob's lane, out of scope) — Linux
   backends won't offer the LAN switch. Intentional.

## Resume command (fresh session)

> "Resume the iOS 'Use Local Network' feature (eb-branch, commit b39217a):
> decide whether to build+install Mac+iOS and verify the LAN-switch tile
> end-to-end, and whether to push."
