# Session handoff — 2026-09-10

## What was asked

Resume the multi-display / any-app work from 2026-09-08 and confirm it works.
The desk turned out to be **Apple Spaces on one display**, not two monitors, so
the feature under test was `b0280d7`'s Space-aware window enumeration rather
than the display chips. That enumeration was broken at the source; it was
replaced. One product rule was added, one build gate was fixed, one new setting
was requested, and the branch was pushed.

## Commits

- `03ef379` — `feat(spaces)`: a desktop with no windows on it no longer gets a
  chip, because the chip only led to a blank grid; a pinned desktop that goes
  quiet falls back to "All Desktops" instead of stranding the filter.
- `7e05ae4` — `fix(spaces)`: two parsing defects in the `com.apple.spaces`
  reader. Superseded by `6863c30`, which removed the mechanism entirely — kept
  in history because the tests it added still describe real behaviour. Also
  teaches `tools/check.sh` the watchOS fallback so the iOS leg stops failing for
  an unrelated machine gap.
- `27b36a9` — `Bound cached content and TTS memory`. **Not from this session** —
  it landed on `eb-branch` at 11:17 while this work was in progress.
- `aac4a1e` — `feat(dictation)`: optional auto-send when you stop speaking, so a
  hands-free flow no longer needs a tap to submit. Off by default.
- `6863c30` — `fix(spaces)`: derive desktops from the window list, not the
  Spaces plist. The fix that finally made the chips appear.

`eb-branch` was **pushed** to `origin/eb-branch` (`5fbf449..6863c30`, 13
commits) after an explicit go-ahead. The branch is in sync. `main` still
rejects direct pushes, so landing needs a PR.

## Why the chips never rendered

`SpaceCatalog` read `com.apple.spaces` from UserDefaults, because macOS exposes
no public Space API. Two parsing defects were found and fixed in `7e05ae4`
(`monitors.first` was correct only by luck on a machine that keeps stale display
records; synthesized `space-N` ids matched no window). Neither was the real
problem.

The real problem only surfaced after the owner said "I could see it working at
one point". Measuring the plist against the live window list on the reporting
desk:

```
Space Properties[].windows   ->  30 distinct window ids
live layer-0 window list     -> 112 windows
overlap                      ->   9
```

The plist tracks desktop pictures and a few system surfaces. It does not carry
app windows. So almost every `WindowState.spaceID` resolved to nil and the phone
had nothing to attribute to a desktop.

Worth recording plainly: `03ef379` — requiring a desktop to hold a window before
it gets a chip — is a correct rule that turned a *visibly* broken feature into an
*invisibly* broken one. Before it, chips rendered off `spaces.count > 1` whether
or not the mapping worked. That is why the owner had seen them once.

## What replaced it (`6863c30`)

`SpaceCatalog` now asks `CGWindowListCopyWindowInfo` twice with different
options:

| Options | Yields |
|---|---|
| `.excludeDesktopElements` | every layer-0 window on every desktop |
| `.excludeDesktopElements` + `.optionOnScreenOnly` | only the active desktop |

The set difference is an honest two-way split: **This Desktop** and **Other
Desktops**. On the desk that measured 9-of-112, this reports 16 windows here and
96 elsewhere, and re-attributes as you switch desktops.

The cost is per-desktop naming — the public API cannot say *which* other desktop
a window sits on. The private `CGSCopySpacesForWindows` can, and was explicitly
declined: two accurate chips beat five that point at nothing. The doc comment on
`SpaceCatalog` keeps the 9-of-112 measurement so nobody re-attempts the plist.

`applyWindowSnapshot` now derives `spaces` from the snapshot it already holds
instead of calling `read()` again, so a poll tick pays for one CG enumeration
rather than two. That closes open thread 3 from the earlier draft of this
handoff.

No phone-side change was needed: `SpaceActivity`, `activeSpaces`, and
`effectiveSpaceID` already drop an empty desktop and hide a one-entry row.

## What else shipped

- `SpaceActivity` in `Shared/MessageProtocol.swift` (deliberately not a new
  `Shared/` file — see US-005 below). `active(spaces:windows:)` keeps only
  desktops holding a window, in the Mac's order; `resolvedSelection(_:active-
  Spaces:)` drops a pick that went quiet.
- `tools/check.sh` grows `ios_generate()`: when `xcrun simctl list runtimes`
  shows no watchOS runtime, generate from a QuipWatch-stripped spec and print
  `note: no watchOS simulator runtime — ran without the QuipWatch target`. The
  generated spec is deleted *after* the suite runs, not before — xcodegen
  records the spec path in the project and `xcodebuild` reopens it.

## Auto-send dictation (`aac4a1e`)

New **Settings → Input → "Auto-send dictation"**, off by default.

- On: `stopRecording` sends the transcript with `pressReturn: true` — hands-free
  end to end. Off: today's behaviour, transcript waits in the prompt.
- The flag is read on the main actor at `stopRecording` time, not inside the
  speech worker's completion, so toggling mid-dictation can't half-apply.
- Rides the prefs backup as `PreferencesSnapshot.dictationAutoSend`; a Mac that
  predates the field decodes as nil and the phone keeps its own value rather
  than being reset to off on every restore.
- Applies to the PTT/dictation path only — the single site that sends a
  transcript. Hand-typed text is unaffected.

Files: `Shared/MessageProtocol.swift`, `QuipiOS/Services/PreferencesSyncService.swift`,
`QuipiOS/QuipApp.swift`, `Shared/Tests/MessageProtocolTests.swift`.

## Install state

| Thing | State |
|---|---|
| `/Applications/Quip.app` | Release at `6863c30`, signed `Developer ID Application: Fintech Adventures LLC (D2PM6R797Q)` at build time, `--verify --deep --strict` clean. Running pid `61727`, started `Sep 10 13:40:56`. |
| `<your-iphone>` | Debug build at `aac4a1e`, installed via `devicectl`, bundle `com.quip.QuipiOS`. `6863c30` is Mac-only, so no reinstall was needed. |
| Stale copies | `/tmp/quip-release`, `/tmp/quip-ios-dd`, `/tmp/quip-mac-dd` all unregistered from LaunchServices and deleted. Only `/Applications/Quip.app` remains for `com.quip.mac`. |
| Working tree | pbxproj restored after every xcodegen run; only the pre-existing untracked `QuipMac/QuipMac.xcodeproj/xcshareddata/`. |

## Hardware-verified vs install-only

| Claim | Evidence |
|---|---|
| Desktop chips render on the phone | **Owner-confirmed on hardware** after `6863c30` installed — the question this session opened with. |
| Phone reconnects cleanly to the rebuilt Mac | **Verified on the wire.** One `ESTABLISHED` socket, `auth=pin`, `client live`. No dual-backend flap. Two pre-handshake reaps in the log are latency probes hitting the 10s `PreHandshakeReapPolicy` deadline, not faults. |
| `SpaceCatalog.split(allWindows:onCurrentSpace:)` | **Test-verified.** 5 cases: all-current, all-elsewhere, mixed, empty, unknown window id. |
| `SpaceActivity` filtering rules | **Test-verified.** 7 cases; proven non-vacuous by mutating the implementation and confirming 4 fail against it. |
| `PreferencesSnapshot.dictationAutoSend` round-trip | **Test-verified.** 3 cases including absent-key-decodes-as-nil. |
| Full gate | **Green.** harness 62 checks, QuipMac 800 tests, QuipiOS 800 tests, `TEST SUCCEEDED` on all three — and again in the pre-commit hook, so `QUIP_SKIP_CHECK` was not needed. |
| Tapping a chip filters the grid, and tapping a card on another desktop switches Space and raises it | **NOT verified.** The row renders; the interactions past that were not walked. `activate(options: [.activateAllWindows])` + AX raise remains untested on hardware. |
| Auto-send dictation | **NOT verified on hardware.** Installed since `aac4a1e`; never exercised. |
| Phone authenticating over LAN | **Still not observed.** The phone authed over Tailscale (`100.x`); the LAN dial (`192.168.4.x`) was reaped before handshake. Known open item, not chased this session. |

## Open threads

1. **Walk the chip interactions.** The row renders. Still unwalked: tap
   "Other Desktops" and confirm the grid filters; tap a card that lives on
   another desktop and confirm macOS switches Space and raises that window; tap
   "All Desktops" and confirm the full grid returns.
2. **Exercise auto-send dictation on device.** Toggle on, speak, confirm it
   submits without a tap; toggle off, confirm the transcript waits in the
   prompt.
3. **Per-desktop names are gone by choice.** If "Desktop 1 / Desktop 2 /
   Desktop 3" is wanted later, the only route is the private
   `CGSCopySpacesForWindows`. Declined deliberately; reopen only if the two-way
   split proves too coarse in daily use.
4. **US-005 still bites plain builds.** A `Shared/` file missing from the
   committed pbxproj makes bare `xcodebuild` fail — this session it was
   `cannot find 'DisplayGeometry' in scope`. `check.sh` hides it by running
   `xcodegen generate` first. New shared code went into `MessageProtocol.swift`
   specifically to dodge this.
5. **A new project folder was requested and never created.** The owner asked to
   add one, chose "new repo on disk" with a bare git setup (git init +
   `.gitignore` + `README.md` + `CLAUDE.md`), then pivoted before naming it. It
   needs a name and a one-line description to proceed.

## Resume in a fresh session

> Read `docs/superpowers/handoffs/2026-09-10-session-handoff.md`. The desktop
> chips render now; start the tail of `~/Library/Logs/Quip/*.log`, check
> `netstat -an | grep 8765`, then walk the chip interactions and the auto-send
> dictation toggle on hardware — both are installed and neither has been
> exercised.
