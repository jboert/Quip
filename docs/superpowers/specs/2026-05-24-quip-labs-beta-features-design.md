# Quip Labs + Three Beta Features — Design

**Date:** 2026-05-24
**Status:** Approved design. §6.1 approach was later revised during implementation — the
shareable unit **extends the existing prompt library + hot-button system** (no new
`.quiprecipe` format). See the implementation plan and the §6.1 notes below for the
as-built approach.
**Branch:** `eb-branch` (local only — do not push)
**Scope:** One combined spec covering a new beta-feature framework ("Quip Labs") and three initial features gated behind it: Cursor CLI support (§7.4), one-tap answers to agent prompts (§3.2), and shareable prompt recipes (§6.1).

> Section numbers (§7.4 / §3.2 / §6.1) refer to the strategy plan that originated these features.

---

## 1. Goals & Non-Goals

### Goals
- Ship a reusable **Labs** beta-gating framework on iOS so experimental features can land opt-in, off by default.
- Add **Cursor CLI** as a first-class agent (`.cursor` `CLIKind`), proving the routing layer is agent-agnostic.
- Let users **answer agent prompts in one tap** — from the lock screen (push actions) and in-app — with the Mac re-validating the prompt is still current before injecting.
- Let users **export/import prompt "recipes"** (prompt + metadata) via the iOS Share Sheet.

### Non-Goals (explicitly deferred)
- No recipe **marketplace backend** (publish / discover / server). Beta is file-share only.
- No multi-step **macro runner** for recipes (recipe = a single prompt + metadata, not an action sequence).
- No generic/config-driven agent profiles — Cursor is hardcoded like the existing agents.
- No new security model — all changes ride the existing PIN + WebSocket trust boundary.

---

## 2. Chosen Approach

**Thin Labs gate on iOS + additive, backward-compatible Mac/Shared changes.**

- Labs flags live on the phone (`@AppStorage`) and gate every **new user-facing surface**.
- Mac-side pieces (Cursor detection/routing, prompt re-validation, recipe metadata) are **additive and back-compat**: a Mac with these changes behaves identically for an un-opted-in phone.
- All new protocol fields are **optional** → old and new peers interoperate (consistent with the codebase's existing forward/backward-tolerant protocol convention).

**Honest cost:** §7.4, §3.2, and §6.1 each touch the Mac app, so this requires **one Mac rebuild**. Per project rule "don't rebuild Mac for iOS-only work," this is justified because the Mac genuinely changes — but it carries the usual TCC re-grant risk (Accessibility + Screen Recording).

Rejected alternatives:
- **iOS-only, defer Mac work** — guts 3 of 4 features into half-features (in-app buttons only; recipes that don't sync; no Cursor detection).
- **No Labs gate, ship to everyone** — contradicts the beta-section requirement and pushes rough features to all users.

---

## 3. Feature Designs

### §0 — Quip Labs (framework)

The foundation everything else plugs into.

**Components**
- `QuipiOS/Services/LabsFlags.swift` — typed registry of beta features. One enum `LabsFeature` is the single source of truth:
  - Each case has: `key` (e.g. `"labs.cursorAgent"`), `title`, `summary` (one line).
  - `LabsFlags` exposes `isEnabled(_:)` / `setEnabled(_:_:)` backed by `@AppStorage`/`UserDefaults`; all default **false**.
- `QuipiOS/Views/LabsSettingsView.swift` — a Settings → **Labs** section. iOS-only. Renders one row per `LabsFeature` (title, summary, `BETA` tag, toggle) under a short "Experimental — may change or break" disclaimer.

**Interface (consumers)**
```swift
if LabsFlags.shared.isEnabled(.cursorAgent) { /* show Cursor in picker */ }
```

**Testing**
- `LabsFeature.allCases` keys are unique.
- Every feature defaults to disabled (no surprise opt-ins on upgrade).

**Isolation:** self-contained in two new files; `QuipApp.swift` only adds a navigation link to `LabsSettingsView` and reads flags at gate points.

---

### §7.4 — Cursor CLI as `.cursor` CLIKind

**Shared**
- `Shared/MessageProtocol.swift`: add `.cursor` to `CLIKind`; add `.cursor` to `SpawnAgent`.

**Mac**
- `QuipMac/Services/TerminalStateDetector.swift`: classify the Cursor agent process as `.cursor`.
  - **To verify during impl:** the exact process name (expected `cursor-agent`) and whether Cursor's TUI needs **paste-routing** (like Codex) or **keystroke-routing** (like Claude Code). Design assumes keystroke; impl confirms and adjusts the routing table.
- `QuipMac/Services/KeystrokeInjector.swift`: add `.cursor` to the input-routing switch (keystroke vs paste per the verified behavior).
- Spawn path (`spawn_window` / `duplicate_window`): support the `cursor` agent preset (launch command verified during impl).

**iOS**
- Labs flag `.cursorAgent` gates adding **Cursor** to the new-session agent picker (commit `1b7a589`) and rendering its icon/label wherever `cliKind` is shown.
- Mac detection/routing ships **un-gated** (additive, safe); only the picker entry + iOS treatment are gated.

**Testing**
- `CLIKind` / `SpawnAgent` round-trip Codable includes `.cursor`.
- Mac classifier maps the Cursor process name to `.cursor` (extend `CLIKindClassifierTests`).

---

### §3.2 — One-tap answers (push + in-app, Mac re-validated)

The highest daily-value feature; also the largest.

**Detection (Mac)**
- Port the pure prompt-detection logic from `QuipiOS/Services/NumberedPromptDetector.swift` to a Mac-side equivalent (shared logic; ~70 lines, no UIKit deps — candidate for a `Shared/` home so both platforms use one copy).
- When a window enters `waiting_for_input`, the Mac computes the **option set** (`[1,2,3]`, or `[y,n]`) and a **prompt fingerprint** = stable hash of the detected option lines (post-ANSI-strip).

**Push payload (Mac → APNs)**
- Extend the push payload with: `windowId`, `options` (the detected set), `promptFingerprint`.
- The notification's `categoryIdentifier` is chosen from a small fixed set based on the option set.

**Notification categories (iOS)**
- Register a fixed set covering the common shapes, respecting the iOS lock-screen cap of **4 actions**:
  - `waiting.yn` → Yes / No (extends today's `WaitingNotificationCategory`)
  - `waiting.12`, `waiting.123`, `waiting.1234` → numbered actions
- Each action carries its answer (`press_y` / `press_n` / `1`…`4`).

**Re-validation (the safety mechanism)**
- Tapping an action sends `QuickActionMessage(windowId:, action:, promptFingerprint:)`.
- Mac handler for `quick_action`: when `promptFingerprint` is present, **re-scrape the window, re-run the detector, and inject only if the current option set still produces the same fingerprint**. On mismatch: drop the injection and send a "prompt changed" push/error rather than misfiring into a changed prompt.
- This realizes the approved "Mac re-validates first" behavior; the fingerprint is the comparison mechanism that makes it reliable.

**In-app contextual buttons (iOS)**
- When the selected window is `waiting` and the iOS `NumberedPromptDetector` finds options, render prominent answer buttons (promotion of the existing numbered chips, §18).
- They send the same fingerprint-tagged `quick_action`, so in-app taps get the same re-validation guarantee.
- Gated by Labs flag `.oneTapAnswers`.

**Testing**
- Mac detector port: reuse iOS `NumberedPromptDetectorTests` against the shared logic.
- Fingerprint match → injects; mismatch → drops + signals.
- `QuickActionMessage` round-trip includes optional `promptFingerprint`.
- Category selection: option set → correct `categoryIdentifier`.

---

### §6.1 — Recipes (prompt + metadata, Share Sheet; no server)

**Model (iOS, Codable)**
```
Recipe {
  body: String            // the prompt text
  title: String
  tags: [String]
  targetAgent: String     // "claude" | "codex" | "cursor" | "any"
  description: String
  version: Int            // schema version, starts at 1
}
```
- Serialized as a self-contained `.quiprecipe` JSON file. Existing `.txt` prompts keep working unchanged (back-compat); recipes are the richer beta format.

**Export (iOS)**
- From a prompt/recipe, present `UIActivityViewController` (Share Sheet) emitting a `.quiprecipe` file.

**Import (iOS)**
- Register the `.quiprecipe` UTI + document type ("Open in Quip"). On open: decode → validate → add to the library → sync to Mac.

**Sync (Mac, additive)**
- Extend `put_prompt` and `prompt_library` messages with **optional** metadata fields (`title`, `tags`, `targetAgent`, `description`, `version`). Old peers ignore them; the on-disk store gains a sidecar or front-matter for metadata (impl picks the least-disruptive option for `PromptLibrary`).

**Gating**
- Labs flag `.recipes` gates the export/import UI and the `.quiprecipe` handling. Plain prompt sync is unaffected.

**Testing**
- `Recipe` encode/decode round-trip, including unknown-field tolerance and version field.
- `put_prompt` / `prompt_library` round-trip with and without metadata (back-compat).
- Malformed `.quiprecipe` import → rejected gracefully.

---

## 4. Protocol Changes (all additive / optional → back-compat)

| Change | Location | Notes |
|--------|----------|-------|
| `CLIKind.cursor` | `Shared/MessageProtocol.swift` | new enum case |
| `SpawnAgent.cursor` | `Shared/MessageProtocol.swift` | new enum case |
| `QuickActionMessage.promptFingerprint: String?` | `Shared/MessageProtocol.swift` | optional; drives re-validation |
| Push payload: `windowId`, `options`, `promptFingerprint` | Mac `PushNotificationService` | APNs JSON fields |
| Prompt-library metadata: `title`, `tags`, `targetAgent`, `description`, `version` | `put_prompt` / `prompt_library` | all optional |

Every change gets a round-trip Codable test (codebase convention).

---

## 5. Component / File Map

**New (iOS)**
- `QuipiOS/Services/LabsFlags.swift`
- `QuipiOS/Views/LabsSettingsView.swift`
- `QuipiOS/Models/Recipe.swift`
- Recipe import/export glue (Share Sheet presenter + UTI handler) — file(s) per impl.

**New (Shared)**
- Shared prompt-detection logic (port of `NumberedPromptDetector`) if hosted in `Shared/`.

**Modified**
- `Shared/MessageProtocol.swift` — enum cases + optional fields.
- `QuipMac/Services/TerminalStateDetector.swift` — Cursor classification.
- `QuipMac/Services/KeystrokeInjector.swift` — Cursor routing.
- `QuipMac/Services/PushNotificationService.swift` — payload options + fingerprint.
- `QuipMac/QuipMacApp.swift` — `quick_action` re-validation; spawn cursor; serve recipe metadata.
- `QuipiOS/QuipApp.swift` — Labs nav link; flag gates; notification categories + action handlers; in-app answer buttons; agent picker entry.

---

## 6. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Cursor process name / routing assumption wrong | Verify empirically in impl before wiring routing; isolate in the classifier + routing switch. |
| Lock-screen action count > 4 (e.g., prompt with 5+ options) | Cap at 4 actions; fall back to "open app to answer" when options exceed the cap. |
| Re-validation false-negative (prompt visually same, hash differs from redraw/ANSI noise) | Fingerprint over **post-ANSI-strip option lines only**, not whole buffer; reuse the detector's existing normalization. |
| Mac rebuild drops TCC grants | Batch all Mac changes into the single rebuild; re-grant Accessibility + Screen Recording after. |
| Recipe import of malformed/hostile file | Strict decode + validation; reject on failure; no code execution, prompt body is inert text. |
| `QuipApp.swift` already very large | Put new logic in dedicated files; touch `QuipApp.swift` only for wiring. |

---

## 7. Out of Scope / Future

- Recipe marketplace server (publish, discover, ratings) — separate platform spec.
- Recipe macros (multi-step `quick_action` sequences) — future.
- Generic user-defined agent profiles — future, once a 4th hardcoded agent proves the routing generalizes.
- Cross-platform parity (Linux/Android) — out of scope (other maintainer's lane).
