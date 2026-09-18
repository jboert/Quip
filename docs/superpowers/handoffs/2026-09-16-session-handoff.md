# Session handoff — 2026-09-16

**Window filter row made opt-in; desktop labels corrected; canvas aspect fixed.**

Branch `eb-branch`, 4 commits, **not pushed**. Nothing installed anywhere.

---

## Commits

| Hash | Why |
|---|---|
| `f50a7a4` | `optionOnScreenOnly` is "currently composited", not a Space membership test — so a minimized window was being reported as living on another desktop, and the phone's default filter deleted its card. Buckets renamed to what they measure: **On Screen** / **Hidden**. |
| `1c2edf2` | The filter row is now `LabsFlags.windowFilters`, off by default, because its default pick REMOVED cards. Same commit drops the 1.45 vertical fudge in `hostScreenRect`, which drew every card 45% taller than the window it stood for. |
| `f697f85` | Wishlist session log: the probe numbers, the three defects, the acceptance tests. |
| `8d55e67` | Wishlist amendment: device build verified, watchOS 26.5 runtime installed, install blocked on the phone rather than on the tree. |

## Install state

| Where | State |
|---|---|
| Mac `/Applications/Quip.app` | **1.5.5 (build 1), Sep 13 20:41** — predates every commit above. Running, pid 83875. Deliberately NOT rebuilt: the only Mac-side change is the bucket labels, which are invisible while the Labs flag is off, and a rebuild costs the Screen Recording + Accessibility TCC grants. |
| iPhone 17 Pro Max (`FA951BBB-D706-5FCF-9886-3E57560E9030`) | **Not installed.** `devicectl device install app` → `CoreDeviceError 1011 … unable to locate a device matching the requested device identifier`. `tunnelState: unavailable`, last connection 2026-09-13. |
| Device build artifact | `BUILD SUCCEEDED`, `QuipWatch.app` embedded, `TeamIdentifier=D2PM6R797Q`, at `$SCRATCH/DD-ios/Build/Products/Debug-iphoneos/Quip.app`. Scratchpad is session-scoped — rebuild rather than hunt for it. |

## Verified vs unverified

| Claim | Evidence |
|---|---|
| `optionOnScreenOnly` is not a Space test | **Measured twice on this desk.** 76 layer-0 windows, 10 pass, 66 misfiled. A Finder window flipped on-screen → off-screen → on-screen across a plain minimize/restore, no Space change. |
| Bucket labels no longer claim a desktop | **Test-verified**, both `split` and the `desktops(inSnapshot:)` path that actually feeds the broadcast. |
| Canvas keeps the desk's aspect | **Test-verified**, 4 cases: ultrawide letterbox, pillarbox, 16:10 on a portrait canvas, nonsense-aspect fallback. |
| Flag off hides nothing | **Read-verified, not run.** `displayWindows` only reorders, never drops, so `filteredWindows == windows` with the flag off. |
| Device build works | **Ran.** Includes the Watch target, which had not compiled here in weeks. |
| Full gate | **Green.** harness 62 checks, QuipMac 865 tests, QuipiOS 811 (806 before this session). |
| Anything at all on hardware | **NOT verified.** No phone, no Mac rebuild. Every user-visible claim below is still a prediction. |

## Environment change worth knowing

`xcodebuild -downloadPlatform watchOS` installed **watchOS 26.5 (23T570), 3.96 GB**. The QuipiOS scheme had been refusing to build *at all* for want of the simulator runtime — device destinations included, not just tests. `tools/check.sh` now runs the real scheme with the `QuipWatch` target; the watch-free `project.nowatch.yml` fallback is off the path and kept only for a future Xcode version bump.

## Open threads

1. **Acceptance test the flag-off grid.** Launch with no Labs flag set: no 26pt chip row above the grid, and every window the Mac broadcasts has a card — including one you minimize while watching.
2. **Acceptance test the canvas.** With the ultrawide attached, a window on the left third of the desk should occupy the left third of the phone canvas, and cards should no longer look vertically stretched. **If the true-aspect band now reads as too short to use, say so** — reverting one line in `hostScreenRect` brings the 1.45 back, and the arrange modes (`gridFrame`) are the intended answer instead.
3. **Display chips have never rendered here.** `NSScreen.screens` reports one display and `displayChipGroup` renders nothing below two, so half of what "screens and displays" names has never been visible on this desk. `DisplayGeometry.spanFrame` has unit tests and zero hardware time. Needs a second monitor.
4. **`MainiOSView.body` is near the type-checker's budget.** One iOS run mid-session died with "the compiler is unable to type-check this expression in reasonable time" pointing at a trivial line inside `body`; the same tree compiled on the next run. Bisected to nothing — it is the body's size. Break `body` up when it next refuses.
5. **Six unrelated files are dirty in the working tree** and were left strictly alone: `PromptLibrary.swift`, `VibeCutSyncService.swift`, `PromptLibraryVibeCutTests.swift`, `PushRegistrationService.swift`, `WatchSyncService.swift`, `WaitingActionResponseTests.swift`. The last three look like a Watch notification-readiness WIP.
6. **Nothing pushed.** All four commits are local on `eb-branch`.

## Flagged at sign-off, NOT investigated

Owner, verbatim (dictated, garbled): *"Going before we make other pusher and
stuff because there's still soon to be other issues with tolling between open
windows."*

Tentative reading, **unconfirmed** — stop pushing for now, because there are
more issues coming with **toggling between open windows**. Nothing was
investigated and no defect has been reproduced. Do not treat this as a spec.
Confirm what "toggling between open windows" means before touching anything;
plausible candidates on this surface, none verified:

- switching the selected card in the grid (`SelectWindowMessage` + the Mac's
  `focusWindow` → `activate(options: [.activateAllWindows])` + AX raise),
- the follow-Mac-frontmost pill fighting a manual tap (`followFrontmost`),
- window ORDER churn across layout updates (`phoneWindowOrder` /
  `reconciledWindowOrder`),
- or the visibility filter hiding the window being toggled to, which today's
  Labs flag should already have taken out of the picture.

## Resume

> Read `docs/superpowers/handoffs/2026-09-16-session-handoff.md`, then run the open-thread 1 and 2 acceptance tests on hardware once the iPhone is back on the cable — build with `xcodebuild -scheme QuipiOS -destination 'generic/platform=iOS' build`, install with `xcrun devicectl device install app --device FA951BBB-D706-5FCF-9886-3E57560E9030 <app>`, and force-quit from the app switcher before judging anything.
