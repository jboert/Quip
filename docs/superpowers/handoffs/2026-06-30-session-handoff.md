# Session handoff — 2026-06-30 (updated)

## Feature: manual "Use Local Network" switch (iOS) + flap fixes

Lets the phone ride the faster LAN path even when paired only over Tailscale.
Justified: this phone's Tailscale **relays via LAX** (`tailscale status` → `relay "lax"`),
not direct-over-LAN, so LAN is materially faster.

## Commits on eb-branch (NOT pushed)

- `b39217a` feat: Use Local Network switch (Mac advertises localURLs in
  DeviceIdentityMessage; iOS learns it, picker tile, permission hint)
- `5027687` fix: reap same-Mac duplicate rows (dual-socket flap)
- `a50149b` / `9d7e925` reverts of the two above (temporary, to stabilize)
- `1453586` / `25ce328` reapply of the two above
- `7676593` **fix: refresh (not accumulate) LAN URLs + soften hint** ← current tip logic
  - C1: `urlsByRefreshingLocal` drops stale LAN-class URLs, replaces with Mac's
    freshly-advertised set (Mac DHCP IP was bouncing .26↔.45; phone hoarded both →
    dialed dead IP → reset pre-auth → flap never converged). ROOT CAUSE.
  - C2: `switchToLANPath` can't pick a stale LAN URL (only live one remains).
  - M1: discovery hint copy softened (was false-positive "Local Network off").

Net: feature IS live at tip (reverts cancelled by reapplies, then C1/C2/M1 on top).

## Verified

- iOS unit tests: **33 green** (URL refresh/reap/classify) on sim CFCE8360 (iPhone 17 Pro, iOS 26.5).
- Mac tests: 3 green (isPrivateIPv4).
- **Simulator connects cleanly** — single path, no flap, full layout. Code is sound.

## NOT verified (hardware, blocked)

- Phone dual-path (TS + LAN) no-flap end-to-end. On-device still flapped, but:
  couldn't confirm the corrected build was the RUNNING process (iOS resumes old
  process unless force-quit — bit us twice), phone Tailscale kept going offline,
  and Mac DHCP IP was actively bouncing .26↔.45 (noise).

## Install state

- Mac `/Applications/Quip.app`: rebuilt this session (Developer ID, pid was 78188),
  **already advertises localURLs** — no Mac rebuild needed for iOS-only fixes.
  Mac LAN IP unstable (.26↔.45 DHCP).
- iPhone 17 Pro Max (devicectl FA951BBB-D706-5FCF-9886-3E57560E9030): corrected
  build `7676593` installed. Feature is iOS-only from here.
- Stale QA-sim UDID in memory (`3B2ACF04…`) is GONE → use `CFCE8360-508E-4A66-B0FD-615D8CD2A549`.

## Next: clean definitive test (in progress)

1. User deletes Quip on phone. 2. Reinstall `7676593`. 3. Pair EXACTLY ONCE over
one path. 4. Confirm single stable ESTABLISHED (netstat 8765). 5. Picker → tap
"Use Local Network" → confirm serverURL flips to current LAN IP, no flap.
One clean pairing removes accumulated test rows muddying the log.

## TOP PRIORITY next — "it should find LAN automatically / remember connections"

User's repeated ask (3×) + the real regression they felt. NOT a code bug — our
repeated delete+reinstall today wiped the phone's connection memory.

Two mechanisms held the LAN before, both local-only (@AppStorage), both wiped on reinstall:
- `paired` backends (auto-connect on launch, multi-backend system)
- `recentConnections` / `recentConnectionsData` (connect-bar list, incl. LAN IPs)

Durable fix (design, not yet built):
1. **Persist connection memory across reinstalls** — back up `paired` + `recentConnections`
   to the Mac over the existing prefs channel (`phonePrefsSnapshot` / PreferencesSnapshot;
   see [[project_phone_prefs_backup]]). Reinstalled phone re-knows recent LANs automatically.
2. **Re-enable Bonjour advertising in Tailscale mode** (QuipMacApp.swift:387-402 currently
   skips it). Gives the phone the LAN URL PRE-auth so it can auth over LAN when the LAX relay
   is down (the chicken-and-egg: localURLs is POST-auth, useless when auth can't complete over
   relay). Safe now that fresh-install single-row + C1 URL-refresh + reap prevent the flap that
   originally justified disabling it. Mac rebuild (TCC reset) required.

Chicken-and-egg confirmed live: phone connects over Tailscale relay (100.72.13.19), socket
ESTABLISHED but auth never completes (57 ENOTCONN mid-auth-roundtrip over LAX relay) → Mac
shows "None connected" → device_identity/localURLs never delivered → LAN never learned →
"Use Local Network" tile has nothing to switch to. Direct LAN pair (ws://192.168.4.26:8765)
sidesteps it. Root: localURLs delivered post-auth can't rescue a phone that can't auth.

## Also requested: clean up Mac Settings page

User asked "clean up settings page" (the QuipMac Settings screen — Server / Connected
Clients / Network Mode sections; `QuipMac/Views/SettingsView.swift`). Under-specified;
brainstorm scope first. Known concrete problem to fix: **"Bonjour discovery: Stopped"
renders with a red ✗ that reads as an error, but in Tailscale mode it's intentional**
(advertising is deliberately off, QuipMacApp.swift:387-402). Relabel/neutralize it in
Tailscale mode ("Off — not needed in Tailscale mode") or hide it, so it doesn't look
broken. Confirm other rows (Port shows 8,765; Bonjour service name "Quip") and whether
Network Mode picker needs clearer help text. Deferred — needs a fresh session.

Note: no user toggle re-enables Bonjour in Tailscale mode. MenuBarView.swift:451-463
server switch calls startAdvertising() but applyNetworkMode() stops it again in TS mode.
Re-enabling = code change (see auto-LAN item above).

## Open

- Push? All local. Do NOT push without explicit OK.
- Tailscale relaying (not direct) is itself fixable (NAT/UPnP) — separate thread.
- Root-cause memory: `project_dual_path_reap_deadlock`; testing pref: `feedback_live_log_during_testing`.

## Resume command

> "Resume Use Local Network hardware test (eb-branch tip 7676593): reinstall phone,
> pair once, verify single stable connection + LAN-switch tile, no flap. Then decide push."
