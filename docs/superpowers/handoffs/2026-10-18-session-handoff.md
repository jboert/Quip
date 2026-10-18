# Session handoff — 2026-10-18

## Commits today (eb-branch, not pushed)

| Hash | Why |
|------|-----|
| `b403fae` | Q-72: the slash palette, its search and the prompts hub follow the selected window's agent (Claude / Codex); universal commands stay, a plain shell lists all. Adds Codex built-ins and an Agent picker on custom slash buttons. |
| `0cd5cdf` | Board row for Q-72 with the hardware check. |

## Install state

| Target | State |
|--------|-------|
| Mac `/Applications/Quip.app` | 1.5.7, binary dated 2026-10-14 07:03. Not rebuilt: Q-72 is phone-only. |
| iPhone 17 Pro Max (`00008150-000248600280401C`) | eb-branch `b403fae`, Debug, installed 2026-10-18 ~05:59. Not yet force-quit and relaunched. |

## Verified vs install-only

| Item | Tests | Simulator | Hardware |
|------|-------|-----------|----------|
| Q-72 slash palette per agent | `SlashAgentsTests` + QuipiOS suite green (1266) | not run | install only |
| Q-72 custom button Agent picker | edit-copy test | not run | install only |
| Q-72 prompts "Other Agents" section | `SlashAgentsTests` hub cases | not run | install only |

## Open threads

1. Q-72 hardware check (board row): force-quit Quip, long-press `/` in a Claude window (expect /btw, /caveman, no /diff), a Codex window (expect /diff, /new, /model, no /btw), a plain shell (everything).
2. `/plan` is tagged Claude only; flip to both in `QuickButton.agents` if Codex has it.
3. VibeCut prompts arrive with `targetAgent: nil` (`Shared/VibeCutPromptMapper.swift`), so they never fold by agent. Mapping VibeCut's `category` to an agent would need a Shared change (both peers).
4. Pinned keyboard-row pills are not filtered by agent; ask the owner whether they should be.

## Resume

Read `docs/superpowers/handoffs/2026-10-18-session-handoff.md`, then run the Q-72 hardware check on the iPhone after a force-quit and relaunch.
