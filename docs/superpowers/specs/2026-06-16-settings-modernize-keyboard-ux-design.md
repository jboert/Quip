# Settings Modernization + Custom-Keyboard UX + Voice-Recognition Accuracy — Design

**Date:** 2026-06-16
**Status:** Draft for approval.
**Branch:** `eb-branch` (local only — do not push without explicit instruction).
**Scope:** Three surfaces — (1) a visual-consistency pass on the Settings sheet, (2) clarity + a new long-press palette for the customizable quick-button row ("the custom keyboard"), and (3) reducing word-mangling in the PTT voice→text pipeline. (1) and (2) are iOS-only with no Mac rebuild; (3) ships an iOS-only fix now and defers the Mac-side piece to the next rebuild.

> Originated from a voice request: *"improve the way the custom keyboard works — it's not very clear how to add keys; you can hold [a key for] a forward slash command…"*, a follow-up to *modernize the settings page*, and a third observation that *the voice translation through Whisper keeps mangling words* (the cause of this very session's garbled prompts — "settings page"→"settings age", "Whisper"→"whisperers", etc.). Scope locked with the user to: **Settings = visual restyle**, **Keyboard = long-press alternates (opt 2) + slash-command keys (opt 3)**, **Voice = stop mangling Quip vocabulary, both paths**.

---

## 1. Goals & Non-Goals

### Goals
- Make **adding a custom key obvious** — the #1 complaint. A first-time user should understand the add flow without trial-and-error.
- **Surface the alternates feature that already exists** (same-first-letter slash grouping) so users discover it instead of being surprised when two buttons merge into a `/c…` menu.
- Add an explicit **hold-any-slash-key → full slash palette** so "hold a key for more commands" works on every slash pill, not only when two share a first letter.
- **Modernize the Settings sheet** for visual consistency: every row uses the same tinted-icon-chip treatment; no hand-rolled one-offs.
- **Stop Whisper/SFSpeech from mangling Quip vocabulary** on *both* the local and remote PTT paths — the systemic input-quality fix.

### Non-Goals (explicitly deferred)
- **No new persistence schema / migration.** All changes are presentation-layer or additive-optional. The `quickSlotsJSON` / `customButtonsJSON` wire formats are unchanged.
- **No Mac rebuild.** Both surfaces are pure iOS (`QuipiOS/QuipApp.swift`). This keeps us off the TCC-re-grant hazard.
- **No per-button user-defined alternate lists.** The hold palette is the fixed set of slash commands (built-in + custom), not a new editable "group" model. (Revisit later if requested.)
- **No system keyboard extension.** "Custom keyboard" here means the in-app accessory button row, not an iOS keyboard target.
- **No settings reorg.** Section consolidation already shipped (`6a01498`, 8→6 sections). This is styling only.
- **No remote-Whisper `initial_prompt` biasing in this pass.** Biasing the Mac's Whisper invocation directly is a Mac change → rebuild → TCC-re-grant risk. Deferred to the next Mac build (§7). The iOS-only post-correction + vocab work covers the remote path's *output* in the meantime.
- **No new speech model / WhisperKit-on-device.** Out of scope; the fix is biasing + correction, not a model swap.

---

## 2. Current State (what already exists)

Honest accounting — most of the requested capability is already built. The gap is discoverability and one missing affordance, not the core feature.

| Capability | Status | Where |
|---|---|---|
| Custom slash-command keys (opt 3) | **Exists** | `CustomPayload.slash` + `CustomButtonForm` (`QuipApp.swift:7063`); built-in slash cases (`QuickButton`, `:5234`) |
| Custom raw-text / keystroke keys | **Exists** | `CustomPayload.rawText` / `.keystroke` |
| Alternates / "hold for variants" (opt 2) | **Partial** | Auto-grouping: slash buttons sharing a first letter collapse into a `/x…` tap-menu (`rowItems` `:4132`, `slashGroupMenuButton` `:4211`). Only triggers when ≥2 share a letter; opens on tap, not hold; invisible until it happens. |
| Add-key flow | **Exists but terse** | `+` → "Custom Button…" → `CustomButtonForm`. No live preview, no guidance, label is a blank required field. |
| Settings rows | **Mostly modern** | `settingsLinkRow` chip style (`:5983`) for most; Latency (`:5837`) and Version (`:5856`) rows are hand-rolled and visually inconsistent. |
| Local-path vocab biasing | **Exists, partial** | `SpeechService` sets `request.contextualStrings = cachedVocab` (`:620`, `:774`) from a bundled `dictation-vocab.txt` (20 terms — includes Tailscale/monospace/Whisper/PTT). Only nudges; only the **local** SFSpeech path. |
| Remote-path biasing | **Absent** | `RemoteSpeechSession.handleTranscript` takes the Mac's Whisper text verbatim. When connected, `selectPTTPath` → remote, so the vocab never applies — this is where the mangling the user sees originates. |
| Transcript post-correction | **Absent** | No substitution/cleanup of returned text on either path. |

**Conclusion:** For keyboard/settings — ship clarity + one new affordance, not a model rebuild. For voice — the local path is already biased but the user mostly hits the **un-biased remote path**; the leverage is a path-agnostic post-correction applied where both transcripts converge.

---

## 3. Chosen Approach

Presentation-layer changes only, in three independent slices that can land and verify separately.

1. **Settings consistency** — add a trailing-`@ViewBuilder` overload to `settingsLinkRow`, route the Latency badge and Version row through it. One visual language for every row.
2. **Add-key clarity** — `CustomButtonForm` gains a live pill preview, auto-derived label, and per-type explanatory footers (including a note that same-letter slash keys auto-group). `QuickButtonsSheet` empty/entry copy points clearly at "+→ Custom Button".
3. **Hold palette (new)** — long-press any on-screen slash pill opens a `Menu` listing every slash command (built-in + custom). Additive `.contextMenu` / long-press; tap still fires the primary action.
4. **Voice accuracy** — expand `dictation-vocab.txt`, and add a path-agnostic `TranscriptCorrector` applied at the point both local + remote transcripts converge (`SpeechService` final-text boundary). Defer Mac-side Whisper `initial_prompt` biasing to the next rebuild.

Rejected alternatives:
- **User-defined alternate groups (editable per button).** Real model + migration + editor surface. Overkill for the stated need; the fixed slash palette already delivers "hold for more commands."
- **Full Settings redesign.** The page is already `insetGrouped` with tinted icon chips; a redesign is churn with low marginal value. Consistency pass captures the win.
- **Whisper-only fix on the Mac.** Highest-quality (biases generation, not output), but requires a Mac rebuild before the user sees any relief and leaves the local path unimproved. The iOS post-correction ships today and covers both paths; the Mac biasing layers on later.
- **Aggressive fuzzy autocorrect of the whole transcript.** Risks "correcting" valid prose. Restrict to a curated, high-confidence Quip-term map with word-boundary matching.

---

## 4. Feature Designs

### 4.1 Settings visual consistency

**Problem.** Most rows render through `settingsLinkRow(title:subtitle:systemImage:tint:trailing:)` — a 28×28 tinted icon chip + title + caption + trailing string. But the **Latency** row (`:5837`) and **Version** button (`:5856`) are hand-rolled `HStack`s, so they read as visually different (no consistent chip, ad-hoc spacing).

**Change.**
- Add an overload `settingsLinkRow<Trailing: View>(title:subtitle:systemImage:tint:@ViewBuilder trailing:)` so a row can supply a trailing *view* (the `LatencySummary…badgeView()`) instead of only a `String`.
- Route the Latency row and the Version row through the chip helper. Version keeps its tap-to-copy + "Copied" confirmation; it just gains the standard `info.circle` chip and layout.
- Keep `macPermsSection` as-is (its red/green semantics are intentional and distinct).

**Files:** `QuipiOS/QuipApp.swift` — `settingsLinkRow` (`:5983`), Diagnostics section (`:5825–5884`).

### 4.2 Add-key clarity (`CustomButtonForm`)

**Problem.** The form (`:7063`) is functional but bare: a blank required **Label** field, an SF-symbol field with no hint of valid names, a 3-way **Type** picker, and a payload field. A new user doesn't know what to type or what the result looks like.

**Changes.**
- **Live preview** at the top — render the actual pill (reuse the same chip chrome as `customQuickButton`, `:4412`) so the user sees the result as they type.
- **Auto-label.** When Label is empty, derive a sensible default from the payload (slash → the command text; text → first ~8 chars; keystroke → the option label). User can still override. Removes the "what do I put here?" stall.
- **Per-type footers** explaining each payload kind in one line:
  - *Slash* — "Sends a `/command`. Turn on Auto-submit for standalone commands like `/clear`; leave it off for ones that take an argument like `/plan`." + "Tip: slash keys that share a first letter automatically group into a `/x…` menu on the row."
  - *Text* — "Sends literal text to the terminal."
  - *Keystroke* — "Sends a control key (Esc, Ctrl-C, Tab…)."
- **SF Symbol hint** — placeholder example (e.g. `bolt.fill`) and a note it's optional / falls back to the label.

**Files:** `CustomButtonForm` (`:7063`).

### 4.3 Hold-any-slash-key palette (new)

**Problem.** "Hold a key for slash commands" only works today when two slash buttons happen to share a first letter (auto-group). On a lone `/plan` pill, long-press does nothing.

**Change.** In `slotRowView` (`:4241`), for slash-category pills (built-in `isSlashCommand` and custom `.slash`), attach a `Menu`-on-long-press (or `.contextMenu`) listing **all** slash commands available — built-in slash `QuickButton`s + every custom `.slash` button — each firing via the existing `fireQuickButton` / `fireCustomButton`. The primary tap is unchanged.

**Design notes.**
- Reuse `SlashGroupMember` (`:4085`) as the menu element type — it already abstracts built-in vs custom and has `displayName`.
- Do **not** apply the palette to answer/keystroke pills (no natural "more like this" set); keep it slash-only so the gesture has a consistent meaning.
- Accessibility: add a hint "Long-press for all slash commands" on slash pills.
- Risk to watch: a long-press menu on a pill inside a horizontally-scrolling row must not eat the scroll gesture. `quickActionButton`/`customQuickButton` are `Button`s; `.contextMenu` coexists with tap. Verify scroll still works (this is the same class of gesture concern the code already documents at `:6419`).

**Files:** `slotRowView` (`:4241`), `quickActionButton` (`:4444`), `customQuickButton` (`:4412`).

### 4.4 Voice-recognition accuracy (both paths)

**Problem.** PTT voice→text mangles Quip-specific words. Root cause is path-dependent:
- The **local** SFSpeech path is biased by `contextualStrings` from `dictation-vocab.txt` (`SpeechService:620`), but the list is short (20 terms) and `contextualStrings` only nudges.
- The **remote** path (Mac Whisper, selected whenever connected — the common case) applies **no** biasing; `RemoteSpeechSession.handleTranscript` returns the Mac's text verbatim. This is the path the user actually hits, so vocab tweaks alone won't fix it.

**Changes (iOS-only, ship now).**

1. **Expand `dictation-vocab.txt`** (`QuipiOS/Resources/dictation-vocab.txt`). Add the terms that demonstrably mangle and the user's working vocabulary: slash-command stems (`compact`, `plan`, `clear`, `prd`, `caveman`, `ultrareview`), agent names (`Codex`, `Grok`, `Cursor`, `Kokoro`), `Simulator`, `keystroke`, `Xcodegen`, `entitlements`, `APNs`, `keychain`, etc. Pure data; only improves the local path but free.

2. **`TranscriptCorrector` (new, the systemic fix).** A small value type holding a curated map of high-confidence mishearings → canonical Quip terms, e.g. `"tail scale"→"Tailscale"`, `"mono type"→"monospace"`, `"x code"→"Xcode"`, `"web socket"→"WebSocket"`, `"co-dex"→"Codex"`. Applied to the **final** transcript (not partials) at the convergence point in `SpeechService` (the `onUpdateCallback(..., isFinal: true)` boundary, `:711`, which both local results and `onTranscriptResult` remote results flow through). Because it sits at the shared sink, it corrects the remote Whisper output too — the part the user complained about — without any Mac change.

   - **Matching rules:** case-insensitive, whole-word/phrase (word-boundary) only, preserve surrounding text and the leading/trailing whitespace the send pipeline depends on. Map is data, unit-tested with the actual mangling examples captured this session.
   - **Conservative by design:** only entries that are unambiguous in a dev/Quip context. Never remap a token that is also a common English word in normal use (skip "pare"/"pay"-class guesses — too risky).

**Changes (Mac, deferred to next rebuild — §7).** Pass the vocabulary list to the Mac with the audio session and set Whisper's `initial_prompt` so the **remote** path is biased at generation time (better than output correction). Tracked as a follow-up; not in this pass to avoid a rebuild now.

**Files:** `QuipiOS/Resources/dictation-vocab.txt`; new `QuipiOS/Services/TranscriptCorrector.swift` + `QuipiOS/Tests/TranscriptCorrectorTests.swift`; wire-in at `SpeechService.swift` (`:98` remote sink, `:711` final delivery).

---

## 5. Risks & Mitigations

- **Gesture conflict (row scroll vs long-press menu).** The quick-button row scrolls horizontally; adding long-press menus could make it feel sticky (the codebase already hit this with `Button` in a `List`, `:6419`). *Mitigation:* prefer `.contextMenu` (system-managed) over a custom `LongPressGesture`; verify scroll on-device before declaring done.
- **Auto-label surprises an editing user.** Auto-fill must only apply when the field is empty and only as a default the user can edit — never overwrite an explicit label. *Mitigation:* fill-if-empty on payload change, not a binding that fights typing.
- **No persistence change, but `CustomButton` may gain no fields.** This design adds **zero** stored fields, so there is no migration surface and old/new installs are byte-compatible. (If a future iteration adds editable alternate lists, that needs the optional-field + `decodeIfPresent` migration path — out of scope here.)
- **TranscriptCorrector over-correcting.** A too-eager map could mangle valid speech (the inverse of the bug). *Mitigation:* curated high-confidence entries only, word-boundary matching, applied to final text only, with a unit test that asserts non-Quip prose passes through untouched.
- **Convergence-point assumption.** The post-correction only catches the remote path if remote transcripts truly flow through the same final sink as local ones. *Mitigation:* confirm `onTranscriptResult` (`:98`) feeds the same `onUpdateCallback(isFinal:)` delivery as local results before wiring; if the remote path has a separate exit, apply the corrector at both.
- **Pure-iOS, but still needs a real build.** Per `project_ws_dual_backend_flap` discipline, presentation changes are low-risk but must be compiled with the Swift-6 oracle (`xcodebuild`, not just SourceKit — see `reference_swift6_compile_oracle`) and visually confirmed on-device before "done."

---

## 6. Verification

| Change | Test |
|---|---|
| Settings consistency | Build; open Settings → Diagnostics → Latency + Version rows render with the standard chip, badge intact, Version still copies. |
| Add-key clarity | Open `+` → Custom Button → type a slash; preview updates live; label auto-fills; footer guidance visible. Save → pill appears on row. |
| Hold palette | Long-press a lone `/plan` pill → menu lists all slash commands → tap `/compact` fires it; single tap still fires `/plan`. Confirm horizontal row scroll unaffected. |
| Voice — vocab | `TranscriptCorrectorTests` asserts the captured mangling examples map to canonical terms; plus a "leave valid prose alone" case. |
| Voice — on-device | Connected (remote path) PTT a sentence with "Tailscale" / "monospace" / "Codex" → transcript shows the canonical spelling, confirming the correction reaches the remote output. |
| Regression | Existing auto-grouping (`/x…`) still works; existing custom buttons still fire; no change to `quickSlotsJSON` / `customButtonsJSON` on disk; non-Quip dictation unchanged. |

All compile-verified via `xcodebuild` (Swift-6 mode); on-device visual confirm on the iPhone 17 Pro Max before marking complete.

---

## 7. Out of Scope / Follow-ups

- **Mac-side Whisper `initial_prompt` biasing (the strongest voice fix).** Send the iOS vocab list to the Mac with the audio session; the Mac seeds Whisper generation with it. Biases at generation rather than correcting output. Needs a Mac rebuild → batch with the next one. **Highest-value follow-up.**
- Editable per-button alternate groups (user-defined "hold" sets).
- SF-symbol picker UI (vs the free-text field).
- Settings full redesign / new sections.
- A user-editable correction map in Settings (ship the curated one first; promote to editable only if users ask).
- Any other cross-platform (Linux/Android) work.
