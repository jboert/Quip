# Review Hardening Loop Implementation Plan

> **For agentic workers:** Implement this plan iteration-by-iteration. Each iteration should compile, pass targeted tests, and be installable before moving to the next. Keep commits small and independently revertible.

**Goal:** Turn the 2026-06 review findings into a short hardening loop that improves Quip's layout UX, prompt CRUD trust, and Mac terminal-state stability without bundling unrelated refactors.

**Architecture:** Four independently shippable iterations. Iteration 1 fixes the most visible Mac layout/order UX. Iteration 2 makes prompt save/delete reliable with explicit protocol feedback. Iteration 3 prevents stale terminal polling from mutating state after windows are untracked or monitoring stops. Iteration 4 closes small UX promises and runs the hardware install loop.

**Tech Stack:** Swift, SwiftUI, Observation, URLSessionWebSocketTask, Network.framework WebSocket server, XCTest, `xcodebuild test`, physical iPhone install via `devicectl`.

---

## File Structure

**Likely modified:**
- `QuipMac/Views/MainWindow.swift`
- `QuipMac/Views/WindowListSidebar.swift`
- `QuipMac/Views/LayoutPreview.swift`
- `QuipMac/Services/WindowManager.swift`
- `QuipMac/Services/TerminalStateDetector.swift`
- `QuipMac/Services/PromptLibrary.swift`
- `QuipMac/QuipMacApp.swift`
- `QuipiOS/QuipApp.swift`
- `QuipiOS/Services/WebSocketClient.swift`
- `Shared/MessageProtocol.swift`
- `docs/protocol.md`
- `docs/superpowers/wishlist.md`

**Likely tests:**
- `QuipMac/Tests/PromptFrontMatterTests.swift`
- New or existing Mac tests for prompt mutation acks and ID sanitization
- New or existing Mac tests for `TerminalStateDetector` stale poll handling if the detector can be made injectable without broad refactor
- Existing iOS build plus targeted iOS tests where protocol state is testable

---

## Iteration 1 - Layout Order And Selected Display

**User value:** The sidebar, preview, and Arrange button agree about which windows go where, and arranging a secondary display does not move windows into the main display's coordinate space.

### Tasks

- [ ] **Unify layout order source.** Pick one ordered ID list for sidebar, preview, and arrange. Prefer `WindowManager.customOrder` as the persisted source and remove or tightly synchronize `MainWindow.windowOrder`.
- [ ] **Fix preview drag reorder.** When `LayoutPreview` calls `onReorder`, update the same order source that `MainWindow.orderedWindows` reads.
- [ ] **Clarify sidebar grouping.** Either stop rank-sorting rows independently, or render explicit sections such as "Enabled terminals", "Enabled targets", and "Other windows" so row numbers do not imply arrange slots.
- [ ] **Respect selected display frame.** Build Arrange target rects from `selectedDisplay.frame` when a display is selected. Keep the single-display fallback unchanged.
- [ ] **Surface arrange failures.** If `WindowManager.arrangeWindows(frames:)` returns false, show a user-visible permission/status message instead of silently doing nothing.

### Verification

- [ ] Mac build: `xcodebuild -project QuipMac/QuipMac.xcodeproj -scheme QuipMac build`
- [ ] Manual Mac smoke: reorder in preview, confirm sidebar and Arrange use the same order.
- [ ] Manual multi-display smoke when available: select secondary display, arrange, confirm windows stay on that display.

### Commit

- [ ] Commit message: `Unify Mac layout order and selected-display arrange`

---

## Iteration 2 - Prompt Mutation Trust

**User value:** Creating, editing, and deleting prompts from iPhone is no longer fire-and-forget. The UI waits for Mac disk-write confirmation and preserves prompt metadata.

### Tasks

- [ ] **Add protocol acks.** Add `PutPromptAckMessage` and `DeletePromptAckMessage` with `messageId`, `id`, `success`, and optional `error`.
- [ ] **Add message IDs to prompt mutations.** Ensure `PutPromptMessage` and `DeletePromptMessage` include optional IDs for ack correlation and Mac dedupe compatibility.
- [ ] **Ack Mac persistence result.** In `QuipMacApp`, send a success or error ack based on `PromptLibrary.put` / `delete`.
- [ ] **Preserve prompt metadata on edit.** iOS edit saves must round-trip `tags`, `targetAgent`, and `description` from the initial `PromptEntry` unless the UI intentionally edits those fields.
- [ ] **Add pending/error UI.** `PromptEditorSheet` should show saving state, keep the sheet open until ack, and display specific errors for disconnected, unauthenticated, timed out, and Mac write failed.
- [ ] **Make delete recoverable.** Gate delete on connected/authenticated state, show failure, and prefer confirmation or undo because deletes mutate disk-backed files.
- [ ] **Validate prompt IDs client-side.** Share or mirror `PromptLibrary.sanitizeID`, show "Will save as ...", block empty sanitized IDs, and warn on sanitized collisions.
- [ ] **Preserve body text.** Avoid trimming the saved body if the UI says prompt text is sent verbatim. Validate all-whitespace bodies separately.

### Verification

- [ ] Mac prompt tests: `xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -only-testing:QuipMacTests/PromptFrontMatterTests`
- [ ] iOS build: `xcodebuild -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination generic/platform=iOS -derivedDataPath QuipiOS/build build`
- [ ] Manual iPhone smoke: create, edit, delete, disconnected save, duplicate sanitized ID.

### Commit

- [ ] Commit message: `Confirm prompt saves and preserve metadata`

---

## Iteration 3 - Terminal Detector Backpressure And Stale-State Guards ✅ SHIPPED `0a1b206` (2026-08-17)

**User value:** The Mac UI and phone state stop flickering or resurrecting stale terminal state when windows close, sessions respawn, or `ps` stalls.

### Tasks

- [x] **Add poll generation.** Increment a generation token on start/stop and capture it with each queued poll.
- [x] **Coalesce polls.** Add an in-flight guard so the 0.25s timer drops ticks while a previous poll is still running.
- [x] **Validate before apply.** Carry `(windowId, originalPid)` through poll results and discard results on main unless the window is still tracked with the same PID or an accepted resolved PID.
- [x] **Invalidate stop cleanly.** `stopMonitoring()` must prevent queued poll results from reinstalling process sources.
- [x] **Move process-exit refresh off main.** (already landed in `f4f15ae`, verified 2026-08-17) Exit handlers should dispatch descendant discovery to `pollQueue` and apply only watch mutations on main.
- [x] **Add focused tests if practical.** Prefer an injectable snapshot/poll application path rather than broad process-spawning tests.

### Verification

- [x] Mac build: `xcodebuild -project QuipMac/QuipMac.xcodeproj -scheme QuipMac build`
- [x] Any new targeted Mac tests. (`TerminalPollGateTests`, 9 cases; suite 694 green)
- [ ] Manual smoke: close tracked iTerm windows during active polling and confirm no stale state or source churn in logs.

### Commit

- [x] Commit message: `Guard terminal polling against stale state` — landed `0a1b206`

---

## Iteration 4 - UX Polish And Hardware Acceptance

**User value:** The app no longer advertises unavailable controls, error states are visible, and the latest build is proven on hardware.

### Tasks

- [ ] **Resolve drag-to-resize promise.** Either implement resize handles backed by `customFrames`, or hide/disable the toggle until a real resize iteration.
- [ ] **Harden terminal spawn paths.** Quote shell paths and escape AppleScript strings so paths with spaces or quotes work.
- [ ] **Accessibility pass.** Convert gesture-only prompt rows to `Button` or add clear accessibility traits/actions. Add labels for icon-only Mac buttons where missing.
- [ ] **Protocol docs.** Document prompt mutation ack messages and timeout behavior in `docs/protocol.md`.
- [ ] **Wishlist closeout.** Update this plan's status in `docs/superpowers/wishlist.md`.
- [ ] **Install latest on iPhone.** Build, install, and launch on the paired iPhone with `devicectl`.

### Verification

- [ ] `git diff --check`
- [ ] Mac targeted tests/build from prior iterations.
- [ ] iOS device build.
- [ ] Physical iPhone install plus launch verification:
  - `xcrun devicectl device install app --device <device> QuipiOS/build/Build/Products/Debug-iphoneos/Quip.app`
  - `xcrun devicectl device process launch --device <device> com.quip.QuipiOS`

### Commit

- [ ] Commit message: `Polish Quip review hardening loop`

---

## Dependency Order

1. Iteration 1 can ship alone and should go first because it fixes visible layout trust.
2. Iteration 2 changes protocol shape, so keep it isolated and update docs/tests in the same commit.
3. Iteration 3 is Mac-only stability and can run in parallel with Iteration 2 in separate worktrees if needed.
4. Iteration 4 should be last because it closes UX promises and runs the full hardware acceptance loop.

## Acceptance Bar

- No dirty tree except intentional plan/status updates after each iteration.
- Each iteration has a focused verification command in the commit/body or final report.
- Any physical install request is complete only after install and launch both succeed, or the blocker is specifically identified.
