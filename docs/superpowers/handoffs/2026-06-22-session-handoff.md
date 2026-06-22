# Session Handoff — 2026-06-22

Long session (spanned 06-21 → 06-22). Three features shipped + pushed; both apps deployed.

## TL;DR
1. **Marker-less lettered choice-menu buttons** — iPhone now renders one-tap buttons for `1. A — …` menus an agent prints as prose (not just `❯`-marker prompts), gated to avoid prose/outline false-positives.
2. **Dual-socket connection-flap fixes** — phone was flapping LAN↔Tailscale every ~60s. Fixed at the source (Mac → `tailscale` mode, Bonjour off) + belt-and-suspenders dedup on both iOS and Mac.
3. **QR pairing → tappable share-link + remote-obtainable** (Ralph PRD, 5 stories, all pass). Tap a `quip://pair` link from Messages/AirDrop → pairs; Mac "Send to iPhone" button; pairing URL respects network mode.

Everything is on **`eb-branch @ 841324e`**, pushed to **`origin/eb-branch`** (`github.com:jboert/Quip`, `7888f79 → 841324e`, 20 commits, clean FF).

## Git state
- Current branch: **eb-branch @ 841324e** (= origin/eb-branch).
- `feat/connection-metrics` (99d4e5d) and `ralph/qr-pairing-share-link` (841324e) still exist — both ancestors of eb-branch now. `feat/connection-metrics` is the **parallel session's** branch (it committed connection metrics / DisconnectReason).
- Uncommitted in the shared tree: `QuipiOS/QuipiOS.xcodeproj/project.pbxproj` (+16 lines) — parallel-session/build churn, left untouched (don't commit/revert without checking with the parallel session).
- **Pushes go to eb-branch only** (user policy: "never push to origin without it coming from eb-branch"). Remote is Jakob's repo; push targets eb-branch, never main.

## Deployed right now
- **Mac**: pid **50212** (new binary, started 06-22 08:20), listening `8765`, Developer ID DR (team `D2PM6R797Q` → TCC survives), `networkMode = tailscale`.
- **iOS**: installed to iPhone 17 Pro Max (`FA951BBB-…`). **Must force-quit + relaunch** to load the new `quip://pair` handler.

## OPEN — pending verification (start here next session)
- **Phone is UNPAIRED** (a clean reinstall this session wiped it). Re-pair using the NEW flow we just built:
  Mac **Settings → Security → "Send to iPhone"** → AirDrop/Message the link → **tap on phone → auto-pairs** over the Tailscale URL.
- **QR pairing on-device verify** — Ralph gated only on compile + the 13 PairingPayload unit tests. NOT yet verified end-to-end on device: tap-to-pair (US-002), Tailscale URL embedded in the link (US-003), the share button (US-004). A watcher was left running to catch the first pair + confirm the connection stays single/stable.
- **Flap fix: VERIFIED single-path (06-22 ~10:55)** — phone connected over ONE Tailscale socket (`100.72.13.19`, no LAN) → the dual-path flap is GONE. It still reset ~2.5 min later (POSIX 54), but a *single*-path 2.5-min reset = **iOS app suspension** (auto-lock/background drops the socket), the inherent foreground-only WebSocket limit, NOT the flap. Keep the app foreground to hold the connection; true background persistence is an iOS constraint (out of scope).

## KEY GOTCHAS learned this session (do not relearn)
- **The Mac app traps SIGTERM.** `killall -w Quip`, `osascript 'quit'`, and `open` on a running instance are **no-ops** — they re-activate the stale process. A whole session ran against **yesterday's binary** because of this. To actually relaunch: `killall -KILL Quip` (untrappable) → confirm `pgrep -x Quip` empty → `open` → **verify a fresh pid / today's `ps lstart`**. (Recorded in `reference_quip_install_recipe`.) Also: `open` right after the kill can throw LS error -600 (race) — retry once the old proc is reaped.
- **`NumberedPromptDetector` is a TWO-PEER contract.** It lives in `Shared/` and drives §3.2 fingerprint re-validation on BOTH Mac and iOS — ship a detector change to BOTH peers or button taps get silently dropped ("Prompt changed — not sent"). (Recorded in `project_numbered_prompt_detector_shared_contract`.)
- **Dual-path flap**: phone reaching the Mac on LAN **and** Tailscale at once flaps every ~60s. Root fix = one path (Mac `tailscale` mode → Bonjour off). Dedup (iOS `0d56a22`, Mac `99d4e5d`) is the self-heal safety net.
- **Native iOS Camera can't open a `quip://` custom-scheme QR** → "No usable data found." Only the in-app Quip scanner or a **tapped shared link** works. Native-Camera support = universal `https://` links = **Phase 2, needs an owned domain** (deferred).
- **SourceKit "cannot find type X in scope"** cross-file diagnostics are spurious noise; `xcodebuild` is the only isolation oracle.
- **Lettered-button detection gating**: marker-less `1. A —` only renders buttons when trailing (≤2 non-empty lines after) AND a choice cue (`?`/pick/choose/select/which/options/go with/consider) within 5 lines above. Buttons also need Labs `oneTapAnswer` for the prominent §3.2 path (compact chips render without it).

## Phase 2 (deferred) — universal links so the native Camera works
Needs a stable owned domain + hosted `/.well-known/apple-app-site-association` (team `D2PM6R797Q`, bundle `com.quip.QuipiOS`, paths `/pair*`) + `associatedDomains` entitlement. Full plan: `~/.claude/plans/parsed-whistling-milner.md`.

## Build / deploy quick-ref
- **iOS**: `xcodebuild build -scheme QuipiOS -project QuipiOS/QuipiOS.xcodeproj -configuration Debug -destination 'platform=iOS,id=00008150-000248600280401C' -derivedDataPath build -allowProvisioningUpdates` → `xcrun devicectl device install app --device FA951BBB-D706-5FCF-9886-3E57560E9030 QuipiOS/build/Build/Products/Debug-iphoneos/Quip.app` → **force-quit + relaunch** on phone.
- **Mac**: `xcodebuild build -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS,name=My Mac' -derivedDataPath build` → `ditto QuipMac/build/Build/Products/Debug/Quip.app /Applications/Quip.app` (NO resign, NO rm -rf) → `killall -KILL Quip` → `open` → **verify fresh pid**.
- **Tests**: `xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:QuipiOSTests/<Class>` (sim must be booted; use `test-without-building` if already built).
