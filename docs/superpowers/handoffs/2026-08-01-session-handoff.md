# Session handoff — 2026-08-01

**Branch:** `eb-branch` · **Unpushed:** 11 commits ahead of `origin/eb-branch` (push NOT run — awaiting explicit confirmation per standing policy)

**One-line summary:** The Quip Mac app was never crashing — it was hanging on blocking calls made on the MainActor. Found the root causes in the macOS hang reports, fixed every stack that appeared in one plus three more of the same class, shipped and installed.

---

## The finding that reframes everything

**There are zero `.ips` crash reports for Quip. There never were.** What exists is `/Library/Logs/DiagnosticReports/Quip_*.hang` — five of them (913s, 85s, 39s, 6.3s, 3.2s) — plus three `Quip_*.cpu_resource.diag` ("90 seconds cpu time over 95 seconds, 95% cpu average"). The app froze, the user force-quit, and that reads as a crash.

**When the user says "Quip crashed": look for `*.hang`, not `*.ips`.**

Every hang stack was the same defect: a blocking system call on the MainActor. The trap throughout this codebase is that **`nonisolated` does not hop off the actor** — a synchronous `nonisolated` func called from `@MainActor` code runs inline on the main thread. That is how `ps` forks, Apple Events probes, and Accessibility round-trips all ended up blocking the UI.

Regression origin: `eaeb380` (2026-06-03) moved the detector's poll loop off main but left the kqueue exit path behind.

---

## Commits (all on `eb-branch`, chronological)

| Hash | Why |
|---|---|
| `0577fb9` | Plan doc — records the four hang reports and their stacks as the evidence base |
| `c6631ef` | Adds `mainThreadProcessSpawns` counter + a test that **fails red** (`"1" != "0"`), proving the bug before any behavior change |
| `f4f15ae` | **The main fix.** kqueue child-exit handler ran a full `ps -ax` on main *per exit*; bursts serialized into the 913s hang. Handler is now pure bookkeeping; `refreshCLIKind` reads the poll loop's published snapshot; dead `pollAllWindows` deleted |
| `0d78a39` | `AEDeterminePermissionToAutomateTarget` (semaphore-blocking Apple Events IPC) ran on main from a 5s timer. Now off-main, coalescing, injectable. `SettingsView` had a *second* copy probing every 3s inside a SwiftUI body — now reads the store |
| `6591304` | `push.log` had reached 231 MB with no rotation anywhere. All 8 append sites now roll at 16 MiB, one generation |
| `e0a459e` | gitignore `.claude-flow` — a broad `git add -A` briefly swept its generated JSON into a commit; amended out and blocked from recurring |
| `370f6bc` | Frontmost-window AX poll made 2 blocking round-trips into whatever app was frontmost, 2.5×/sec forever. Off main + in-flight guard; 50pt match tolerance extracted pure and tested |
| `13fdb41` | cloudflared log was slurped whole on main every second against a growing file. Now incremental from a byte offset, off main. `pgrep` orphan sweep also moved off main |
| `e451f57` | Marks the plan implemented; records the two deliberate deviations |
| `9239cb3` | Wishlist — the six remaining blockers of the same class, with `file:line` and fix shapes |

**Tests: 636 → 663, 0 failures.** Full suite verified green after every behavioral commit.

---

## Install state

| | State |
|---|---|
| **Mac** `/Applications/Quip.app` | **Installed this session.** v1.5.5 (CFBundleVersion `1`). Release, Developer ID `D2PM6R797Q`, hardened runtime. Live pid **9912**, started 14:21:46 |
| **iOS device** | **Not touched.** No iOS build, no `devicectl install`. Zero iOS code changed this session |
| **Signature** | `valid on disk` + `satisfies its Designated Requirement`. DR is team-keyed on `subject.OU = D2PM6R797Q` with **no cdhash literal** — TCC grants should survive future rebuilds |
| **Stale builds** | Cleaned. Unregistered + deleted the 1.8 GB `DerivedData/QuipMac-*` tree (a second on-disk `com.quip.mac` with a *different* cdhash — the thing that breaks TCC re-granting) and `/tmp/quip-release` (622 MB). `/Applications/Quip.app` re-registered and is the only macOS `Quip.app` on disk |

Next Mac test run rebuilds DerivedData from scratch — expect one slow run.

---

## Verified vs. install-only

| Item | Status |
|---|---|
| 663 unit tests green | ✅ **Verified** — full `xcodebuild test` run |
| Bug proven real before fixing | ✅ **Verified** — red state observed: `("1") is not equal to ("0")` |
| Release build signs correctly | ✅ **Verified** — full `codesign`/`spctl` audit, DR confirmed cdhash-free |
| Only one macOS `Quip.app` on disk | ✅ **Verified** — filesystem check after cleanup |
| App launches, binds 8765 | ✅ **Verified** — fresh pid 9912 confirmed (the app traps SIGTERM, so this was checked, not assumed); `netstat` shows LISTEN; zero AMFI/codesign-kill events |
| **Hangs actually gone** | ❌ **NOT verified — install-only.** Cannot be proven in-session; needs days of real use. This is the open acceptance test |
| Phone reconnects after install | ❌ **Not verified** — user action. Restarting the Mac app drops every connection |
| TCC grants survived the install | ❌ **Not verified** — user should confirm Accessibility + Screen Recording still work (keystroke injection, screenshot view) |
| Hardened-runtime feature paths | ❌ **Not verified** — WhisperKit PTT, cloudflared tunnel, Kokoro TTS, iTerm Apple Events all need hands-on use |

---

## Open threads

**1. The acceptance test (the only real proof).** Run Claude Code sessions that spawn many short-lived children in a tracked terminal window, with Settings → General open, for a few days. Then `ls -lt /Library/Logs/DiagnosticReports/ | grep -i quip`. Baseline to beat: 5 hangs + 3 cpu_resource reports between 2026-07-27 and 2026-08-01. **Any new `Quip_*.hang` — read its main-thread stack before assuming it's one of the known open items.**

**2. Six remaining main-thread blockers**, same defect class, no hang report yet. Full list with `file:line` and fix shapes is in `docs/superpowers/wishlist.md`. Ranked by exposure, the top two:
- `WhisperDictationService.ingest(_:)` (`:66`) — base64 decode + `queue.sync` on main, once per PTT audio chunk
- `PINStore.read()` (`:110`) — synchronous `SecItemCopyMatching` during `App.init`; the file's own comment at `:88-92` already records a sampled hang on this exact stack

**3. Two signing flags noticed, not acted on.** `com.apple.security.get-task-allow = true` in the Release build (harmless locally, would block notarization). `CFBundleVersion` still `1`.

**4. Push is pending.** 11 commits unpushed. Not run — standing policy is no push without explicit confirmation.

---

## Resume command for a fresh session

> Read `docs/superpowers/plans/2026-08-01-main-thread-hang-fixes.md` and the "Main-thread hangs" section of `docs/superpowers/wishlist.md`, then check `ls -lt /Library/Logs/DiagnosticReports/ | grep -i quip` for any `Quip_*.hang` newer than 2026-08-01 — if none, pick up the six remaining main-thread blockers starting with `WhisperDictationService.ingest`; if there is a new one, read its main-thread stack first.
