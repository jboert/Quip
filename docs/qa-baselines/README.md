# QA visual baselines

Reference screenshots of the Quip iOS app's main view for visual-regression diffing. Refresh after intentional UI changes; diff against these whenever a release lands to catch unintended drift (especially theme regressions like the hardcoded `Color.white.opacity(0.15)` chip-fill bug fixed in `031ddc2`).

## Files

| File | Captured | What it covers |
|------|----------|----------------|
| `main-light.png` | 2026-05-05 (commit `031ddc2` + `9ef47de`) | Main view — Connected, window cards (Quip + nugget-expo), terminal panel (always dark by design), main row buttons, slot row chips (`/btw  /help  Y  N  1  2  Esc  ⌫`), v1.5.2 footer. Theme = Light. |
| `main-dark.png` | 2026-05-05 | Same view, Theme = Dark. |

Both captured on the dedicated **Quip QA simulator** (iPhone 17 Pro Max iOS 26.4, UDID `D853A014-E5D8-46F1-A81D-37860AA9DFA2`).

## How to refresh

```bash
SKILL=/Users/erickbzovi/Projects/claude-skills/ios-simulator-skill/ios-simulator-skill/skills/ios-simulator-skill/scripts
UDID=D853A014-E5D8-46F1-A81D-37860AA9DFA2
BASE=docs/qa-baselines

# Light
python3 $SKILL/navigator.py --udid $UDID --find-text "gearshape" --tap
sleep 1 && idb ui tap --udid $UDID 220 315  # Light segment
sleep 1 && idb ui tap --udid $UDID 383 99   # Done
sleep 2 && xcrun simctl io $UDID screenshot $BASE/main-light.png

# Dark
python3 $SKILL/navigator.py --udid $UDID --find-text "gearshape" --tap
sleep 1 && idb ui tap --udid $UDID 340 315  # Dark segment
sleep 1 && idb ui tap --udid $UDID 383 99   # Done
sleep 2 && xcrun simctl io $UDID screenshot $BASE/main-dark.png
```

Picker segment x-coords (in points, on iPhone 17 Pro Max 430pt-wide screen):
- Auto: `100`
- Light: `220`
- Dark: `340`
- y: `315` (constant)
- Done button: `(383, 99)`

## How to diff against a fresh build

```bash
SKILL=/Users/erickbzovi/Projects/claude-skills/ios-simulator-skill/ios-simulator-skill/skills/ios-simulator-skill/scripts
mkdir -p /tmp/quip-current

# Capture current build's screenshots the same way as above, but writing to /tmp/quip-current/
# ...

# Then:
python3 $SKILL/visual_diff.py docs/qa-baselines/main-light.png /tmp/quip-current/main-light.png --threshold 0.05
python3 $SKILL/visual_diff.py docs/qa-baselines/main-dark.png /tmp/quip-current/main-dark.png --threshold 0.05
```

Threshold `0.05` = 5% pixel difference passes (terminal content / clock / battery icon naturally drift). Bump higher for terminal-heavy areas; tighter for chrome-only diffs.

## When to refresh baselines

- After any intentional UI change that touches the main view (slot row layout, main-row button additions, color tokens, status bar, version string).
- When the `appearance.mode` picker semantics change.
- When the seeded demo custom button changes.

The terminal-panel content rendered inside Quip will differ on every capture (it shows live Mac iTerm output) — the diff threshold accommodates that. If you need a tighter diff, scroll/clear the Mac iTerm window first so the terminal panel area is neutral.
