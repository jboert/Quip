# Session handoff — 2026-08-03 (multi-select, live-probed)

Branch `eb-branch`, 10 commits, none pushed. Started from "multiple selection
prompts still not working — test better", which turned out to be four separate
defects, none of which the existing tests could have caught: every fixture in the
suite was hand-written from imagination, and all three assumptions in them about
Claude Code's widget were wrong.

**The method that found them:** drive the real TUI. Spawn a widget in an iTerm2
session, inject single keystrokes by `unique id`, read `contents` back, and watch
what the widget actually does. Every claim below was measured that way, not
reasoned about. See [[project_agent_cli_prompt_dialects]].

## Commits

| Hash | Why |
|------|-----|
| `2c57768` | Multi-select submitted only one pick. Return on an option row TOGGLES it (footer: "Enter to select") — the trailing Return was flipping the last pick back off. Commit means walking onto an unnumbered `Submit` row, then confirming a review step. Also: the checked box is `[✔]` U+2714 (unrecognised, so the diff flipped correct boxes), and terminals pad the buffer to full window height, pushing prompts past the detector's scan window. |
| `2dec128` | A single-option tap typed digit + Return, but both dialects act on the digit instantly — the Return answered whatever screen came next, silently confirming Codex's default reasoning level. Now digit-only, with a content-verified Return. Also made redaction canonical at the read so phone and Mac hash identical bytes. |
| `b9664e4` | Terminal.app reads asked for "contents of front window". Its AppleScript `id of window` IS the CGWindowID (verified: 72 and 968 matched `CGWindowListCopyWindowInfo`), so reads now target the requested window. |
| `9ab3c93` | The wishlist recorded a *guess* — "Claude's TUI toggles on the number key" — and pointed future sessions at the wrong fix point. Replaced with what was measured. Added the board. |
| `51df71d` | Live widget shapes locked in the **iOS** suite. The phone draws the chips from the same shared detector but only had invented fixtures — the exact gap that hid all of the above. |
| `7c7fcba` | "APNsJWTTests hangs the suite ~57 min" was stale: re-measured at 0.018s for 7 tests, unskipped. Documented the one live hazard (`keyPEM` defaults to a Keychain read, evaluated per call site). |
| `7cf350a` | Codex image upload under Terminal.app dead-ended — routed to clipboard bytes, but `pasteImage` only drives iTerm2, so uploads failed after the photo was already saved. codex-cli 0.146.0 opens a typed path itself ("Viewed Image └ …" then described it), so Terminal.app takes the typed-path route. |
| `e6c1d90` | Clipboard offered only `public.tiff`; now TIFF + PNG + file URL as one item, TIFF still primary. |
| `ec9308b` | A rule under the options now ends the menu, so "Chat about this" is no longer a tappable chip. Structural (length-gated run of rule characters), never label text. |
| `56ed531` | `tasks/` is gitignored, so every board update was silently untracked while `git status` reported clean. Board moved to `docs/superpowers/board.md`. |

## Install state

- **Mac** — `/Applications/Quip.app` rebuilt and installed from `ec9308b`,
  Aug 3 22:35, running as pid 5632. Developer ID (D2PM6R797Q), seal valid, TCC
  survived. Stale build copies unregistered and deleted after each install.
- **iPhone** — still on the **08:5x build**, which is `2c57768`-era: it HAS the
  `[✔]` + Submit-row detector, it does NOT have the divider rule. It will keep
  offering "Chat about this" as a chip until reinstalled. `devicectl` reports the
  device `unavailable` (Bonjour pairing → needs USB or same Wi-Fi, unlocked).

## Verified how

| Claim | Evidence |
|-------|----------|
| Space toggles; Return on an option row toggles too | Injected into a live widget; `[ ]` → `[✔]` → `[ ]` observed |
| Submit row + review step commits the picks | Full sequence injected; session logged `⏺ User answered Claude's questions: → Banana, Durian` |
| Codex acts on a bare digit and advances | `/model` picker: digit selected the model AND moved to reasoning-level; fingerprint changed `fd8f9e87…` → `1313ad12…` |
| Codex reads a typed image path | Terminal.app codex TUI logged `Viewed Image └ …/quip-test-image.png` and described the checkerboard |
| Terminal window id == CGWindowID | AppleScript ids 72/968 matched `CGWindowListCopyWindowInfo` exactly |
| Everything else | Unit tests only — 51 shared-harness checks, 678 Mac, 740 iOS |

**Install-only, NOT exercised:** the phone→Mac WebSocket leg of any of this, the
image paste itself, and the PNG/file-URL clipboard payload. A dev shell cannot
drive them: System Events keystrokes need an Accessibility grant it does not
have, and the Mac requires a PIN, so the WS hop cannot be scripted. Only Quip
itself and a paired phone can close those.

## Open threads

- **Q-A1** — phone→Mac acceptance: tap 2+ options in a Claude multi-select,
  Submit; the terminal must list every pick under "Review your answers" and land
  on `⏺ User answered Claude's questions`.
- **Q-A2** — install the current iOS build (blocked on device reachability).
- **Q-6b** — "Type something" is still offered as a chip; it sits ABOVE the rule
  inside the real option list, so the divider rule cannot reach it and label
  matching is the wrong tool.
- **Q-7** — ~16 swallowed errors from `2026-07-13-swallowed-errors-audit.md`,
  not yet broken into tickets.
- **Not merged, not pushed.** 10 commits sit on `eb-branch` per the standing
  rule that pushes need explicit per-push confirmation.

## Resume

Read `docs/superpowers/board.md`, take the top Ready ticket, and probe any TUI
claim live before trusting a fixture.
