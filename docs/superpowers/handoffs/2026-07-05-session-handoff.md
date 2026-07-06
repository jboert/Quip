# Session handoff — 2026-07-05

Two features shipped to **eb-branch** via swiftc-gated Ralph loops; neither is
built or installed yet (see matrix). No Mac rebuild this session — TCC grants
intact.

## Shipped today (eb-branch)

### 1. Multi-select `[✓]` pre-check sync
Fixes the reported bug: an interactive Claude checkbox prompt with options Claude
pre-checked (`[✓]`, "Recommended") rendered as empty boxes on the phone, and
submitting from the phone space-toggled the already-checked options OFF.
Root-caused (Mac toggle path assumed an all-unchecked start), then built via a
5-story loop; swiftc harness = 21 checks.

- `9c6d3d9` US-001 — detector `checkedOptions(in:)` + `cursorOption(in:)`.
- `7edd03b` US-002 — `MultiSelectSync.togglesToReach` (ascending symmetric diff).
- `44da2b8` US-003 — `MultiSelectSync.keystrokes(desired:liveContent:)`.
- `dab5a5d` US-004 — Mac `revalidateAnswer` toggles only the diff vs live `[✓]`.
- `cea089d` US-005 — iOS `MultiSelectAnswerBar` seeds picks from `checkedOptions`, re-seeds on fingerprint change.
- `23632c8` chore: re-untrack scaffolding · `1139161` docs: wishlist (autocomplete ask).

### 2. Accept Claude's autocomplete from the phone (Right-arrow / ESC[C)
Terminal shows greyed ghost text; phone couldn't accept it. Added the accept
keystroke path end-to-end. 4-story loop; swiftc harness green; agent also ran
`xcodegen`+Mac build (BUILD SUCCEEDED) and restored pbxproj (zero diff).

- `8335ebc` US-001 — `Shared/TerminalKeyBytes.csi(for:)` CSI table (up/down/right/left/end).
- `073901b` US-002 — `KeystrokeInjector` learns `"right"` (iTerm2 write-expr `((character id 27) & "[C")` + keyCode 124) + locked in `KeystrokeInjectorWriteExpressionTests`.
- `117b72d` US-003 — Mac `handleQuickAction` `press_right` → `sendKeystroke("right")`.
- `d6fe2f2` US-004 — iOS compact accept-suggestion button → `quickAction("press_right")`.

New files: `Shared/MultiSelectSync.swift`, `Shared/TerminalKeyBytes.swift`,
`tools/run-multiselect-tests.sh`, `tools/run-accept-autocomplete-tests.sh`, `tools/main.swift`.

## Install / verification matrix

| Feature | In git (eb-branch) | Compiles | Installed | Hardware-verified |
|---------|--------------------|----------|-----------|-------------------|
| multiselect `[✓]` sync | ✅ | ❌ not run | ❌ | ❌ |
| accept-autocomplete | ✅ | ✅ Mac build in-loop; iOS not built | ❌ | ❌ |

**Nothing installed this session.** `/Applications/Quip.app` + the iPhone run
whatever was there before today. Both features need `xcodegen generate` first
(zero-pbxproj protocol — new Shared files not in committed pbxproj).

## Open threads (need USER — hardware/decisions)

1. **Multiselect** — xcodegen → rebuild QuipMac → confirm a Recommended prompt keeps 1 & 2 selected when answered from phone; install QuipiOS → bar shows 1 & 2 pre-checked.
2. **Accept-autocomplete** — confirm the accept key on a LIVE prompt. Wired to Right-arrow (ESC[C). If Right doesn't accept, swap iOS mapping to `"end"` (ESC[F, already in `TerminalKeyBytes`) — one line. Then build QuipMac + install QuipiOS.
3. Periodic cleanup as ralph branches accrete (both `ralph/*` branches now merged; `git branch -d` them).

## Resume command (fresh session)

"On Quip eb-branch: xcodegen generate, build QuipMac + QuipiOS, install both, and
hardware-verify today's two features — multiselect `[✓]` pre-check sync and
phone accept-autocomplete (Right-arrow; swap to `end` if it doesn't accept)."
