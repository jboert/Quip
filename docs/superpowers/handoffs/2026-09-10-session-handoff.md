# Session handoff — 2026-09-10

## What was asked

Resume the multi-display / any-app work from 2026-09-08 and confirm it works.
It turned out the desk is **Apple Spaces on one display**, not two monitors, so
the feature under test was `b0280d7`'s Space-aware window enumeration rather
than the display chips. Two defects in that parsing surfaced, one product rule
was added, one build gate was fixed, and one new setting was requested.

## Commits

- `03ef379` — `feat(spaces)`: a desktop with no windows on it no longer gets a
  chip, because the chip only led to a blank grid; a pinned desktop that goes
  quiet falls back to "All Desktops" instead of stranding the filter.
- `7e05ae4` — `fix(spaces)`: read the display macOS labels `Main` rather than
  `monitors.first`, which landed on the live screen by luck; drop synthesized
  `space-N` ids that matched no window. Also teaches `tools/check.sh` the
  watchOS fallback so the iOS leg stops failing for an unrelated machine gap.
- `27b36a9` — `Bound cached content and TTS memory`. **Not from this session** —
  it landed on `eb-branch` at 11:17 while this work was in progress.

- `aac4a1e` — `feat(dictation)`: optional auto-send when you stop speaking, so a hands-free flow no longer needs a tap to submit. Off by default.

`eb-branch` is **12 ahead of `origin/eb-branch`** and has NOT been pushed. A
Stop hook asked for a push; the standing rule is that pushes need the owner's
explicit per-instance go-ahead, and a hook is not the owner.

## The two defects in b0280d7

Both live in `WindowManager.SpaceCatalog`, which parses `com.apple.spaces`
because macOS exposes no public Space API.

1. **`monitors.first` was right by luck.** macOS keeps a collapsed record for
   every display ever attached. On this desk the array is
   `["Main", <stale UUID>, <stale UUID>]` — first happened to be the live one.
   A reorder would have pointed Space enumeration at an unplugged screen and
   reported its desktops. Same class as the `NSScreen.main` defect from
   2026-09-08. Now `primaryMonitor(in:)`: prefer `Display Identifier == "Main"`,
   then any display that actually carries `Spaces`.
2. **Synthetic desktop ids.** With no monitor carrying Spaces, the parser still
   walked `Space Properties` and built ids from the index — `space-1`,
   `space-2` — which match no window's `spaceID`. That is a chip that filters
   to nothing. A property with no `ManagedSpaceID` behind it is now skipped.

Found by test, not by inspection: `testSpaceCatalogIsEmptyWhenNoMonitorCarries-
Spaces` failed on the first run and exposed defect 2.

## What shipped

- `SpaceActivity` in `Shared/MessageProtocol.swift` (deliberately not a new
  `Shared/` file — see US-005 note below). `active(spaces:windows:)` keeps only
  desktops holding a window, in the Mac's order; `resolvedSelection(_:active-
  Spaces:)` drops a pick that went quiet.
- `SpaceCatalog.parse(root:)` split out as a pure function so the monitor
  selection and window→desktop mapping are testable without a live WindowServer.
- `tools/check.sh` grows `ios_generate()`: when `xcrun simctl list runtimes`
  shows no watchOS runtime, generate from a QuipWatch-stripped spec and print
  `note: no watchOS simulator runtime — ran without the QuipWatch target`.

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
| `/Applications/Quip.app` | Release, binary mtime `Sep 10 11:59:19`, signed `Developer ID Application: Fintech Adventures LLC (D2PM6R797Q)` at build time, `--verify --strict` clean. Running pid `73759`, started `11:59:31`. Contains `7e05ae4`. |
| iPhone 17 Pro Max (`FA951BBB-D706-5FCF-9886-3E57560E9030`) | Debug build at `27b36a9`, installed via `devicectl`, bundle `com.quip.QuipiOS`. Does **not** contain the auto-send setting. |
| Stale copies | `/tmp/quip-*` scratch from the prior session removed (~900MB); the Release build copy unregistered from LaunchServices. |
| Working tree | pbxproj restored after every xcodegen run; only the pre-existing untracked `QuipMac/QuipMac.xcodeproj/xcshareddata/`. |

## Hardware-verified vs install-only

| Claim | Evidence |
|---|---|
| `SpaceActivity` filtering rules | **Test-verified.** 7 cases; proven non-vacuous by mutating the implementation and confirming 4 fail against it. |
| `SpaceCatalog` monitor selection + window mapping | **Test-verified.** 5 cases on the real payload shape: Main not first, Main first, no Main label, nothing carrying Spaces, window→desktop mapping. |
| `PreferencesSnapshot.dictationAutoSend` round-trip | **Test-verified.** 3 cases including absent-key-decodes-as-nil. |
| Mac app is current and running | **Verified.** Fresh pid, `nm` shows 1465 `space` and 20 `DisplayGeometry` symbols in the installed binary. |
| `check.sh` watchOS fallback | **Verified.** iOS leg ran green through the fallback and the pre-commit hook passed on `7e05ae4`. |
| **Do the desktop chips render on the phone at all** | **NOT verified.** The whole session's open question. Owner reported "i dont see one", then "hard to tell". Both peers have since been rebuilt and reinstalled; not re-checked after that. |
| Tapping a desktop chip filters the grid | **NOT verified.** Blocked on the above. |
| Tapping a card on another desktop switches Space and raises it | **NOT verified.** `activate(options: [.activateAllWindows])` + AX raise is untested on hardware. |
| Auto-send dictation | **NOT verified on hardware.** Suites green; not yet built or installed to the phone. |

## Open threads

1. **The chip row.** Force-quit Quip on the phone from the app switcher,
   relaunch, reconnect, and look above the window canvas for
   `Desktop 1` · `Desktop 2` · `All Desktops`. The desk has 2 Spaces
   (`ManagedSpaceID` 1 and 3) holding ~16 and ~19 windows, so both qualify. If
   the row is still absent, it is no longer a stale-bundle question on either
   side — instrument `SpaceCatalog.read()` at runtime rather than guessing,
   since everything verified about it so far is static or unit-level.
2. **Ship auto-send dictation.** Build, install, and confirm on device
   that speaking with the toggle on submits and with it off does not.
3. **`SpaceCatalog.read()` runs twice per poll tick** — once in
   `fetchWindowList()`, once in `applyWindowSnapshot` — each a full
   `persistentDomain` parse on the main actor. Not measured; a hang suspect
   given the project's history of MainActor-blocking hangs.
4. **US-005 still bites plain builds.** A `Shared/` file missing from the
   committed pbxproj makes bare `xcodebuild` fail — this session it was
   `cannot find 'DisplayGeometry' in scope`. `check.sh` hides it by running
   `xcodegen generate` first. New shared code was put in `MessageProtocol.swift`
   specifically to dodge this.
5. **Push is blocked pending the owner.** 12 commits ahead. `main` rejects
   direct pushes, so landing needs a PR.

## Resume in a fresh session

> Read `docs/superpowers/handoffs/2026-09-10-session-handoff.md`, then start the
> tail of `~/Library/Logs/Quip/*.log`, check `netstat -an | grep 8765`, and find
> out whether the desktop chip row renders on the phone — that is the one thing
> this session never managed to verify.
