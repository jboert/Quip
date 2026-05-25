# Session Handoff — Quip Labs beta features (2026-05-24)

## Goal
Ship four features behind an opt-in iOS **Quip Labs** section, by **extending existing
systems** (user directive: "add to the existing prompt library", "hot button", "only
improve" — no parallel systems).

- §0 Quip Labs framework (opt-in Settings section, flags default off)
- §7.4 Cursor CLI as a 4th agent (`.cursor`)
- §3.2 One-tap answers: dynamic push actions + Mac re-validation + in-app buttons
- §6.1 Prompt/hot-button **packs**: share + import, extending the prompt library

Authoritative design: `docs/superpowers/specs/2026-05-24-quip-labs-beta-features-design.md`
(note: §6.1 there originally proposed a new `.quiprecipe` format — **superseded**, see below).
Implementation plan (full step list): `~/.claude/plans/polished-wondering-garden.md`.

## Status

| Feature | State |
|---|---|
| §0 Quip Labs | ✅ DONE, committed `9003bcd` |
| §7.4 Cursor | ✅ DONE, committed `9003bcd` |
| §3.2 One-tap answers | ⏳ NOT STARTED |
| §6.1 Prompt/button packs | ⏳ NOT STARTED |

Tests after `9003bcd`: **QuipMac 346 / QuipiOS 367, all green.** Branch `eb-branch` (local, never push).

## Key environment facts learned this session
- **Projects are xcodegen-globbed** (`path: .` + `path: ../Shared`, Tests globbed into test
  targets). Adding/moving a `.swift` file needs only `xcodegen generate` in each project dir —
  **no manual `.pbxproj` surgery**. Commit the regenerated `.pbxproj`.
- **iOS unit tests need watchOS 26.5 runtime** (the iOS scheme builds the embedded Watch app).
  Installed this session (`xcodebuild -downloadPlatform watchOS`). Already present now.
- **Dedicated QA sim is gone.** Use `iPhone 17 Pro 26.4.1` UDID `3D46A3C6-01E3-42FB-8E08-DC8B259FCE49`.
  (Saved-memory default `D853A0…` is stale.)
- **Cursor CLI not installed here** → `cursor-agent` process name + paste-vs-keystroke routing
  are **assumptions**; verify on a device with Cursor. Currently routed like Claude (sendText).
- Test commands (mirror CI):
  - `xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`
  - `xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination 'platform=iOS Simulator,id=3D46A3C6-01E3-42FB-8E08-DC8B259FCE49' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=""`
  - Fast inner loop: add `-only-testing:QuipMacTests/<SuiteName>`.

## What shipped in `9003bcd`
- `Shared/MessageProtocol.swift`: `CLIKind.cursor`, `SpawnAgent.cursor`.
- `QuipMac/Services/TerminalStateDetector.swift`: `classifyCLI` matches `cursor-agent`
  (precedence below codex, above node→claude); `isAIProcess` includes `cursor-agent`.
- `QuipMac/QuipMacApp.swift`: image-upload routing `.cursor`→sendText; `spawnCommand(.cursor)`→`"cursor-agent"`.
- `QuipiOS/Services/LabsFlags.swift` (NEW): flag-key registry + `LabsSection` + `LabsToggleRow`.
- `QuipiOS/QuipApp.swift`: `LabsSection()` in `SettingsSheet` (before Prompts); Cursor gated in
  agent picker via `labs.cursorAgent`; `.cursor` handled in `shortHint`, `duplicateSpawnAgent`,
  `SpawnAgent.displayName`.
- `QuipMac/Tests/CLIKindClassifierTests.swift`: +4 cursor tests.
- Labs flag keys (all default false): `labs.cursorAgent`, `labs.oneTapAnswer`, `labs.promptPackSharing`.

## Remaining: §3.2 One-tap answers (next up)
Detailed steps in the plan file. Summary:
1. **Move** `QuipiOS/Services/NumberedPromptDetector.swift` → `Shared/NumberedPromptDetector.swift`
   (`git mv`, then `xcodegen generate` both). Existing `QuipiOS/Tests/NumberedPromptDetectorTests.swift`
   stays green (`@testable import Quip`; detector still compiled into the Quip target via Shared glob).
2. **Add** (TDD, tests in `Shared/Tests/`): `fingerprint(in:) -> String?` (FNV-1a over normalized
   option lines — stripANSI → trim → drop `❯ `/`> ` marker → collapse whitespace; no new deps) and
   `detectYesNo(in:) -> Bool`.
3. `Shared/MessageProtocol.swift`: `QuickActionMessage.promptFingerprint: String?` (optional, init nil).
4. **Mac** (`QuipMacApp.swift` waiting transition ~`:329-356`; `PushNotificationService.notifyWaitingForInput`):
   scrape window via `keystrokeInjector.readContent(...)`, detect options + fingerprint, add optional
   payload keys `quip_options`/`quip_prompt_fingerprint`, pick `aps.category` via a pure
   `category(forOptions:)`.
5. **iOS** (`PushNotificationCenter.swift`): category set `waiting.yn/.12/.123/.1234` (+ keep legacy
   `waiting_for_input` fallback for >4 / non-numeric); `WaitingActionResponse` +`.choiceThree/.choiceFour`;
   delegate echoes `quip_prompt_fingerprint`; dispatch closure (`QuipApp.swift:245-257`) unifies numbered
   answers onto `QuickActionMessage(action:"select_N", promptFingerprint:)`.
6. **Mac re-validation** in `handleQuickAction` (`QuipMacApp.swift:1808`, plumb fingerprint from decode
   site `:1127-1176`): for `select_N`/`press_y`/`press_n` only — nil fingerprint → inject as today;
   else re-scrape + recompute fingerprint, inject only on match (and N still present), else drop +
   `ErrorMessage("Prompt changed — not sent")`.
7. **In-app** (`QuipApp.swift:4915-4943`): gate behind `labs.oneTapAnswer`; flag off → chips unchanged;
   flag on + window waiting → prominent buttons; both send the fingerprint (extend `onSendAction` `:3190`).
8. Tests: fingerprint stability/sensitivity/nil; `category(forOptions:)`; QuickActionMessage round-trip
   ±fingerprint; re-validation decision fn (match/mismatch/nil/N-absent); WaitingActionResponse ids.

## Remaining: §6.1 Prompt/hot-button packs
Detailed steps in the plan file. Summary: `SharedPromptPack` (iOS-only file
`QuipiOS/Services/SharedPromptPack.swift`, reuses `PromptEntry`+`CustomButton` verbatim, never on the
wire); optional metadata (`tags`/`targetAgent`/`description`) on `PromptEntry`+`PutPromptMessage` +
on-disk `<!-- quip:meta -->` front-matter in `PromptLibrary` (byte-identical legacy output when absent);
export via `DiagnosticsShareSheet`; import via `.quippack` UTI in `QuipiOS/Info.plist` + file branch in
`.onOpenURL` (`QuipApp.swift:304`) + `ImportPackSheet` preview; prompts → extended `PutPromptMessage`,
buttons → append with reminted UUIDs to `customButtonsJSON`/`quickSlotsJSON`. Gate on
`labs.promptPackSharing`.

## Final step (after §3.2 + §6.1)
One Mac rebuild + reinstall (re-grant Accessibility + Screen Recording per project rule), and on-device
verify: Cursor spawn/classify; one-tap answer (incl. stale → "Prompt changed"); pack export→import.
