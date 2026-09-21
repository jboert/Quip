# Session handoff — 2026-09-20

**Wand gained an on-screen filter, the terminal's ghost text now reaches the phone, and the window list stopped churning. Everything is installed on both peers.**

Branch `eb-branch`, 5 commits, **not pushed**. Mac and iPhone both carry today's build.

---

## Commits

| Hash | Why |
|---|---|
| `e05b066` | `MainiOSView.body` was one ~535-line chained expression and had already failed once with "unable to type-check this expression in reasonable time" on an unrelated one-line edit (Q-26). Split into four staged computed properties plus two overlay closures; modifier order byte-for-byte unchanged. |
| `daf30bb` | Board: Q-26 moved to Done. |
| `30cf282` | Wand: opt-in "Only windows on screen". With it on, a window that is not composited — minimized to the Dock, or on another Space — is switched OFF rather than skipped, because skipping is the Q-24 bug (a window nothing can clear stays on forever). If nothing of a checked kind is on screen the whole selection is a no-op, so minimizing your last terminal cannot turn the wand into a desk-clearing button. |
| `e369c2c` | Autosuggest end to end. `terminal_content` now carries `autosuggest {typed, suggestion}` instead of only a `hasAutosuggest` bit; the phone renders the ghost row, accepting mirrors `typed + suggestion` into the compose field, Send in that state presses Return instead of retyping, and editing the mirror wipes the Mac's line first. Rules in `Shared/InputLineSend.swift`, pure and tested. |
| `626968e` | The reported "windows come and go" was XPC services owning layer-0 windows. Measured first (88 samples / 500ms / 45s): 79 windows, 23 owned by `.prohibited` processes, and every one of the 10 list transitions was a `CursorUIViewService` window; `isOnVisibleScreen` churn was zero. `fetchWindowList` now skips `.prohibited` owners; `.accessory` (Stream Deck, HazeOver) stays. |

## Install state

| Peer | State |
|---|---|
| Mac | `/Applications/Quip.app`, binary mtime **Sep 20 19:32:36**, pid verified fresh after launch. `CFBundleShortVersionString` still reads **1.5.5** — the version string is not bumped by the build, so trust the binary mtime, not the plist. Signed `Developer ID Application: Fintech Adventures LLC (D2PM6R797Q)`, hardened runtime, `satisfies its Designated Requirement`. No re-grant prompt seen; no TCC denials or AMFI kills in `log show`. |
| iPhone (`00008150-000248600280401C`) | `devicectl device install app` succeeded at 19:2x with the `e369c2c` bundle. **Not yet force-quit and relaunched**, so the phone may still be running the old process — that is the first thing to do next session. |
| Stale builds | Cleaned: `/tmp/quip-release`, `/tmp/quip-ios`, `DerivedData/QuipMac-*` removed and unregistered; `mdfind -name 'Quip.app'` shows only `/Applications/Quip.app` plus the iOS-simulator build. |

## Verified vs install-only

| Change | Evidence |
|---|---|
| `e05b066` split | Compiles; QuipiOS 824 tests green. No UI regression check on hardware. |
| `30cf282` wand filter | QuipMac 884 tests green (5 new). **Not exercised on hardware** — nobody has checked the box in Settings → General → Sort button and tapped the wand with a minimized terminal. |
| `e369c2c` autosuggest | swiftc harness 62 checks, QuipMac 897, QuipiOS 824, all green. **Not exercised on hardware** — needs a live ghost suggestion in a terminal, with the phone relaunched. |
| `626968e` window filter | QuipMac 901 tests green (4 new). The measurement that motivated it is real; the *fix's* effect on the live list has not been re-sampled after install. |

Nothing from today has been confirmed by a human looking at a screen.

## Open threads

- **Which surface is flapping.** `626968e` fixes the Mac sidebar. The phone's default broadcast filter (`isEnabled || (isTarget && isOnVisibleScreen)`, `mirrorDesktop = 0` on this machine) already excluded XPC windows, so if the *phone grid* is what comes and goes, that is a separate cause and needs its own measurement with the phone connected. The user was asked and has not answered.
- **Phone relaunch.** Force-quit Quip on the iPhone and relaunch before testing anything from `e369c2c`.
- **Board `ready` items still needing a human**: Q-17a, Q-19b, Q-16, Q-18a (manual smoke, all need the phone), Q-22 (needs the owner's call on `_AXUIElementGetWindow`, a private API, vs public-only matching), Q-27 (needs a screenshot of a real duplicate prompt), Q-25 (grid acceptance).
- **Phone was reachable again** at 19:0x over Tailscale (`100.72.13.19` → `100.120.141.122:8765`), first connection since 2026-09-13, which unblocks the smoke items whenever there is a human to run them.
- **Build gotcha worth remembering**: the committed `project.pbxproj` does not enumerate every source file — a raw `xcodebuild` failed on `WandSort.swift` and `OutputActivityTracker` before `xcodegen generate`. `tools/check.sh` regenerates internally, so green tests do not prove a raw build links. Recorded in memory.
- **Not pushed.** Per the standing rule, every push needs its own confirmation; `main` is protected and would need a PR.

## Resume command

> Read `docs/superpowers/board.md` and this handoff, confirm the iPhone has been force-quit and relaunched, then ask which surface the flapping window list was on (Mac sidebar or phone grid) before measuring further.
