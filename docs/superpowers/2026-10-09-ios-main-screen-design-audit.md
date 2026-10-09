# Design audit — Quip iPhone main screen

**Surface used:** (1) renders supplied: the simulator screenshots taken this session of the current build `383c7db` (`int1.png` full screen, `color3.png` full screen with a terminal window selected, `qb5-row.png` quick row crop, `int5-crop.png` card menu). The code read for every finding matches those renders (same commit). Findings marked **[render]** were seen in the pixels; **[source]** came from the code only (light mode in the renders; dark-mode values checked in the token file).

**Stack:** SwiftUI (Swift 5 mode, iOS 17 target). Styling is a hand-rolled token struct, `QuipColors` (`QuipiOS/Views/QuipTheme.swift:4`), injected via `@Environment(\.colorScheme)`; window identity colours come from `WindowColor.palette` (`Shared/WindowColor.swift:12`); key tints from `KeyColors` (`QuipiOS/Services/KeyColors.swift`). Written project decisions audited against: CLAUDE.md, memory rule "Compact UI: new controls use icons, fit existing rows, expansion toggles over fixed growth", and the window-palette-as-identity convention. There is **no typography or spacing token layer**: sizes are literal (`.system(size: 9/10/11/13)`, `padding(10)`, corner radii 5/7/10/12/14). That is itself a finding (§1).

## Step 1 — Understanding

The main screen is a remote for terminal windows on a Mac: a scale-model grid of window cards (top), the selected window's live terminal with a 7-icon toolbar (middle, most of the height), then a main row of 9 icon buttons centred on the mic and a row of user-configured quick keys (bottom), with a thin status strip ("Connected · no mic", gear) above and a build stamp below. Primary goal: read what the selected agent is doing and answer it, by voice or a quick key.

**Focal element:** the terminal panel (reading) with the mic as the primary CTA. The panel wins by area and by being the only dark surface. The mic wins the control row only modestly: it is the widest tile and the only red glyph, but it is one of nine same-height, same-fill tiles, so it reads as "one of the buttons" rather than "the button" (**[HIGH]**, §2).

## Overall Score: 7/10

Strong information architecture and state-richness for a dense tool, held back by one real accessibility defect (card titles in the window colour fail AA on their own tinted fill) and sub-44 pt targets in the main row.

## 1. Visual Design

| Subcategory | Score | Note |
| --- | --- | --- |
| Spacing & whitespace | 7 | Consistent 10/12 pt rhythm inside cards and panel; grid card is inset ~44 pt per side while the terminal panel is inset 9 pt, so the two main surfaces do not share a left edge **[render]**. Intentional (scale model of the Mac desk, `hostScreenRect`), so a pass with a note. |
| Typography | 5 | Weight-based hierarchy inside cards is right (bold caption title, caption2 subtitle). But the system has five literal micro sizes (8, 9, 10, 11, 13 pt) with no tokens; 9 pt is used for status hints, key labels and the build stamp, under the 11 pt floor for comfortable reading. |
| Color restraint | 8 | Neutral surface, one semantic green status dot, window colour as the only accent per card: disciplined, and the system's own rule. Red is overloaded: it means "record" (mic glyph) and "denied" ("no mic") in the same viewport **[render]**. |
| Alignment / grid / balance | 7 | Mic is geometrically centred by flexible spacers (`QuipApp.swift:3005-3010`), clusters are balanced. Grid card vs panel edge mismatch noted above. |
| Clutter & visual noise | 6 | 25 icon targets below the fold (9 main, 9 quick, 7 toolbar). Each is justified by the compact-UI rule and configurable, so not a defect in itself, but the nav chevrons at 24 pt wide read as filler **[render]**. |

**Already strong:** the window-colour system (border, title, ⋯ button, terminal border and status dot all in the window's colour) makes selection unmistakable without a label; `KeyColors.prefersDarkText` picks black on yellow/lime (16.4:1) and white on purple (5.7:1), so user-chosen key tints never fail contrast **[source, computed]**; the empty state has a real CTA ("New Window") not just a message (`QuipApp.swift:4644-4662`).

Issues:

- **[CRITICAL] [render + computed]** Card title is drawn in the window colour on a 10 % tint of the same colour (`QuipiOS/Views/WindowRectangle.swift:117-121`: `.foregroundStyle(windowColor)` over `.fill(windowColor.opacity(isSelected ? 0.2 : 0.1))` at line 98). Light mode ratios against the project's own palette: green `#7ED321` 1.63:1, orange `#F5A623` 1.75:1, yellow `#F8E71C` 1.15:1, blue `#4A90D9` 2.78:1; only red (4.36:1) and purple (4.40:1) pass. The "dotfiles"/"orchard-api" titles in `int1.png` show it. Fix: keep the colour on the border, pin, ⋯ and glow; set the title in `colors.textPrimary` and let the 2 pt border carry identity:
  ```swift
  // WindowRectangle.swift:117-121
  Text(primary)
      .font(.caption.weight(.bold))
      .foregroundStyle(colors.textPrimary)
  ```
  If the coloured title must stay, gate it the way `KeyColors.prefersDarkText(on:)` already does: `.foregroundStyle(KeyColors.prefersDarkText(on: window.color) ? colors.textPrimary : windowColor)` passes red/purple/blue-ish and falls back to text colour for the pale ones.
- **[HIGH] [computed]** Card secondary line is `colors.textSecondary.opacity(0.7)` (`WindowRectangle.swift:129`): black at 0.385 alpha on the tinted card = 2.67:1 at 11 pt (caption2). Drop the extra opacity: `colors.textSecondary` alone is 4.68:1 on the background and ~4.5:1 on a 10 % tint.
- **[MEDIUM] [source]** No typography/spacing tokens. `QuipTheme.swift` holds colours only; type sizes are literals across `QuipApp.swift` (e.g. `:2762`, `:2768`, `:3419`, `:5963`) and `WindowRectangle.swift`. Add a `QuipType` enum next to `QuipColors` with `caption = Font.system(size: 11)`, `micro = Font.system(size: 10, weight: .medium)` and retire 8/9 pt.
- **[MEDIUM] [render]** Red carries two meanings in one strip: `ptt.color` for "no mic" denial (`QuipApp.swift:2760-2770`) and the mic glyph in the main row. Use `colors.recording` (the existing amber token, `QuipTheme.swift:128`) for the mic glyph and leave red for denial.
- **[LOW] [computed]** Build stamp `v1.5.7 …` is 9 pt `colors.textTertiary` (`QuipApp.swift:3419-3421`): 2.43:1. Acceptable as a diagnostic stamp; if it is meant to be read, `colors.textSecondary` gets it to 4.68:1.

## 2. UX & Usability

| Subcategory | Score | Note |
| --- | --- | --- |
| Information hierarchy & scan path | 8 | Top-down: which windows → what the selected one says → what to do. Grid-to-panel link by colour is excellent. |
| CTA clarity & prominence | 6 | Mic is the primary action but shares height, fill and radius with eight siblings (`QuipApp.swift:3005-3030`). Quick keys carry user colour while the mic does not, so a tinted "Y" out-shouts the mic **[render, qb5-row.png]**. |
| Cognitive load | 7 | Three rows of icons is a lot, but every one is configurable and the compact rule is the system's choice. The new ⋯ and the hint line remove the hidden-menu problem (Q-61). |
| Form usability / labels / feedback | 7 | Every control has an accessibility label; disabled quick keys dim to 0.4 and say "No window selected". Colour changes and pins reflect only after the Mac rebroadcasts, with no optimistic feedback **[source]**. |
| Keyboard & focus visibility | 8 | VoiceOver: card is one button with a hint, actions rotor from the context menu, ⋯ hidden so double-tap still selects. No hardware-keyboard focus ring work, but this surface is touch-first. |
| Mobile / resize behavior | 8 | Portrait/landscape sizes branch (`navW/navH`, `QuipApp.swift:2940-2941`); terminal expand/collapse toggle reclaims height; cards reflow with the Mac aspect. |

Issues:

- **[HIGH] [source]** Main-row nav chevrons are 24 × 36 pt in portrait (`QuipApp.swift:2940-2941`), under the 44 pt HIG minimum; the visual can stay narrow, the hit area cannot. Fitts: these are the most-repeated taps on the screen.
- **[HIGH] [render]** Mic does not win the row. One-token fix: fill the mic tile with `colors.recording` (or `colors.buttonPrimary`) and white glyph; keep every other tile on `colors.surface`.
- **[MEDIUM] [source]** Quick-key labels are 9 pt monospaced with `minimumScaleFactor(0.55)` (`QuipApp.swift:5963-5966`), so a long custom label can render at ~5 pt. Raise the floor to 0.8 and the size to 11; let the chip grow by the existing `padding(.horizontal, 4)` instead.
- **[MEDIUM] [source]** Card tap has no pressed state: selection is an `.onTapGesture` on the ZStack (`WindowRectangle.swift:171-173`), so nothing happens under the finger until the spring runs. See §3.
- **[LOW] [source]** Empty-state CTA uses a literal `Color.blue.opacity(0.7)` (`QuipApp.swift:4659-4661`) where `colors.buttonPrimary` exists (`QuipTheme.swift:109`).

## 3. States Coverage

Verified in code (hover is n/a on iOS).

| Element | Pressed | Focus (VoiceOver) | Disabled | Notes |
| --- | --- | --- | --- | --- |
| Window card | **missing** (plain `onTapGesture`, no highlight) | label + value + hint, actions rotor | eye-slash overlay at `WindowRectangle.swift:159-167` | selected (scale 1.02, 2 pt border), thinking (spinning ✽), waiting (glow + pulse dot), pinned, minimized, dragging ghost all present |
| ⋯ menu button | system Menu highlight | hidden by design | none needed | — |
| Main-row buttons | default `Button` press only (no `pressedHighlight` token used) | labels present | chevrons `.disabled(windows.count <= 1)` with `textFaint` | `colors.pressedHighlight` exists (`QuipTheme.swift:117`) but is **unused** on this row |
| Quick keys | default | label + "No window selected" hint | 0.4 opacity + disabled | tinted keys keep 1.0 fill when disabled (`:5973`, `tint == nil` branch) so a coloured key looks live while dead |
| Terminal toolbar | default | labels | 0.2 alpha + `.disabled` at size limits | 1.86:1 for disabled glyphs is fine (exempt) |

Data surfaces:

| Surface | Loading | Empty | Error |
| --- | --- | --- | --- |
| Window grid | **missing**: between auth and first `layout_update` the grid shows "No windows" with a New Window CTA (`QuipApp.swift:4644-4650`), which is wrong for ~1 s and invites spawning a duplicate | present | none at grid level; connection error is the 9 pt red text in the header (`:2777-2781`) |
| Terminal panel | **missing**: no spinner or skeleton while `request_content` is in flight; the previous window's text stays until the new one arrives | shows the Mac's placeholder string for non-terminals (`int1.png`) | no "couldn't read this window" state; a dead window just stops updating |

## 4. Top 5 Fixes

1. **Card title contrast** (`QuipiOS/Views/WindowRectangle.swift:117-121`) — the only AA failure that hits every card:
   ```swift
   let primary = (window.folder?.isEmpty == false ? window.folder! : window.app)
   Text(primary)
       .font(.caption.weight(.bold))
       .foregroundStyle(colors.textPrimary)   // identity stays on the border, pin, ⋯, glow
       .lineLimit(1)
       .truncationMode(.tail)
   ```
2. **Secondary line alpha** (`QuipiOS/Views/WindowRectangle.swift:127-131`):
   ```swift
   Text(window.folder?.isEmpty == false ? window.app : window.name)
       .font(.caption2)
       .foregroundStyle(colors.textSecondary)   // was .opacity(0.7): 2.67:1 → ≥4.5:1
       .lineLimit(1)
       .truncationMode(.tail)
   ```
3. **Nav chevron hit area** (`QuipiOS/QuipApp.swift:2940-2941` and the two chevron buttons at `:3014-3040`). Keep the 24 pt pill, widen the target:
   ```swift
   let navW: CGFloat = isPortrait ? 24 : 22
   let navH: CGFloat = isPortrait ? 36 : 28
   // on each chevron Button's label, after .clipShape(RoundedRectangle(cornerRadius: 10)):
   .frame(minWidth: 44, minHeight: 44)
   .contentShape(Rectangle())
   ```
4. **Mic as the one accent tile** (`QuipiOS/QuipApp.swift`, the mic button in the main row): background `colors.recording`, glyph `.white`, every other tile stays `colors.surface`. Also frees red for "denied" only.
5. **Quick-key label floor** (`QuipiOS/QuipApp.swift:5963-5966`): `.font(.system(size: 11, weight: .semibold, design: .monospaced))` and `.minimumScaleFactor(0.8)`; and in the disabled branch (`:5973`) apply the 0.4 opacity to tinted keys too so a coloured key cannot look live while disabled.

## 5. Premium Polish

- **Concentric radii.** Card radius is 12 (`WindowRectangle.swift:97`), the ⋯ circle sits 4 pt inside it; the terminal panel and main-row tiles use 10 and 14. Derive inner radii as outer − inset (12 − 4 = 8 for anything nested in a card; 14 − 4 = 10 for tiles inside the panel) so corners read as one family.
- **Tabular numbers** on anything that changes: the terminal title `120×36`, the "N paired" count (`QuipApp.swift:2739`) and the build stamp — add `.monospacedDigit()` so widths stop jittering on update.
- **Pressed feedback under 300 ms.** Give the card a press scale using the existing token: wrap the ZStack in a `Button` with a custom `ButtonStyle` that overlays `colors.pressedHighlight` and scales to 0.98 for `configuration.isPressed` with `.animation(.easeOut(duration: 0.12))`; keep `.contextMenu` and the ⋯ Menu as they are. Add `.sensoryFeedback(.selection, trigger: isSelected)` (iOS 17) so a card tap is felt as well as seen.
