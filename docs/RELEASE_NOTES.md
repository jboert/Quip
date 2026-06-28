# Release Notes — eb-branch → 2026-06-28

For Jakob. Summarizes what eb-branch adds since the last pull. Pull `eb-branch`.

> **Rebuild both peers.** The smart-answer work changes the **Shared/** detector
> contract, which drives fingerprint revalidation on *both* Mac and iOS. Ship Mac
> and iOS together or taps silently drop ("Prompt changed — not sent").

## Features

### Smart answers — inline bracketed choice prompts (§18.3)
Claude/Codex also prompt on a single **inline** line — `Continue? [yes/no]`,
`Approve which to delete? [all / 1 / 2 / 3 / none / pick]` — not line-prefixed
`N.` options. The old detector keyed only on per-line numbers, so these rendered
no buttons.
- **Shared detector:** new `detectInlineOptions(in:)` single-line scanner —
  trailing `[ … ]`, same-line choice cue, splits on `/`, accepts only
  charset-safe tokens with ≥1 digit or known anchor word (all/none/yes/no/pick/…).
  Rejects `array[0]`, `rm -rf [dir]`, `[docs](url)`, `[foo / bar]` prose.
  `fingerprint` gains an `inline:` branch (numbered wins ties).
- **iOS:** `InlineAnswerBar` — one chip per token, single tap. Digits reuse
  `select_N`; words send new `answer_text:<word>`.
- **Mac:** types token + Return; membership check (token must be in
  `detectInlineOptions(liveContent)`) is the real guard.

### Smart answers — multi-select for Claude `[ ]` checkbox menus (§18.2)
Claude checkbox menus are model-emitted **text**; user answers by typing picks.
- iOS `MultiSelectAnswerBar` accumulates picks → one `select_multi:1,3` submit.
- Mac toggles each digit + one Return. One-submit avoids per-tap drop (screen
  doesn't mutate until submit).
- Correctness follow-ups: text-submit keystroke fix + detector body-line/task-list
  guards.

### Phone grid drag-to-reorder fixed
Card drag never engaged — inner `onTapGesture` + `contextMenu` won as
descendants. Fixed via `.highPriorityGesture`. Plus follow-ups: cycle order,
override migration, tests.

## Chores / docs
- `swrm.md` — swrm project manifest.
- Session logs + handoffs (2026-06-23, 2026-06-24).

## Tests
Detector 48 (iOS), AnswerRevalidation 18 (Mac) — all green.

## Still pending (on-device, needs hardware)
- TUI keystroke path for multi-select (number = toggle) unverified live.
