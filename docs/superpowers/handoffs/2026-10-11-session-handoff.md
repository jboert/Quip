# Session handoff — 2026-10-11 (follows 2026-10-09-session-handoff.md)

## Resume in one line

On eb-branch run `git log --oneline origin/eb-branch..eb-branch` (Q-67, its follow-up, Q-68 and this handoff, not pushed), install `f551a0d` on the owner's iPhone once it is reachable, then ask how holding a button (edit, spacer) feels.

## Branch state

- eb-branch is clean apart from the ruflo junk (`ruvector.db`, `agentdb.rvf`, `agentdb.rvf.lock`, untracked, left alone).
- `origin/eb-branch` is at `ecd4d03` (Jakob's CI commit, pulled fast-forward this session). Not pushed: `f02cb28` (Q-67) and this handoff. They wait for the owner's word, as the standing rule says.
- Gate at `f02cb28`: QuipiOS 1184 tests green (harness and QuipMac skipped, since nothing under Shared/ or QuipMac/ changed).

## Commits since the last handoff (newest first)

| Hash | Author | Why |
| --- | --- | --- |
| `f551a0d` | this session (2026-10-12) | Q-68: Add Spacer After in the hold menu; spacers are 28 pt tall so they can be held (Add Spacer After, Remove from Row). |
| `4651edb` | this session (2026-10-12) | Q-67 follow-up: the edit form preview shows the slot's color; Edit… on prompt pills opens `PromptEditorSheet`; dead slash `.contextMenu` became a VoiceOver action. |
| `f02cb28` | this session | Q-67: holding a quick-row button still opens a menu (Edit…, Color…, Remove from Row, plus All Slash Commands… or Paste & Send). Tapping a Row Order entry in Settings opens the edit form. Editing a built-in makes a custom copy in its slot and keeps its color (`QuickButtonEdit`). |
| `ecd4d03` | Jakob | CI builds Apple targets on macos-26; the QR render is SDK-portable. |
| `98888a5` | Jakob | Mac stability: AppleScript compiled-script cache (works around the macOS 27 parser fault), wake the display before keystrokes, 1400px JPEG screenshots, Kokoro on the CPU with a 10-minute idle shutdown, tidier terminal text, 15 s Tailscale timeout, `.claude-flow/` excluded in project.yml. |

## Install state

| Peer | Installed | Missing |
| --- | --- | --- |
| Mac `/Applications/Quip.app` | 1.5.7, `QuipBuildCommit = 98888a5` (Jakob's fixes are in), binary dated 2026-10-09 19:22, pid 20605, 8765 listening, phone ESTABLISHED from 192.168.4.50. | `ecd4d03` is CI-only plus a QR render tweak, so no rebuild is needed. |
| iPhone (owner's primary) | eb-branch `4651edb`, Debug, installed 2026-10-12 ~09:17. | `f551a0d` (Q-68). The 2026-10-12 install failed: device `unavailable` (owner remote). Install when it is back: build `-scheme QuipiOS`, then `devicectl device install app`. |
| QA simulator D8C5154B | Gate test host at `f02cb28`. It is paired to the fake Mac; its quick row now holds a custom `/btw2` and a custom `Y` from QA. The fake was stopped and the sim rebooted. | — |

## Hardware-verified vs install-only

| Work | Unit tests | Simulator (fake Mac) | Hardware |
| --- | --- | --- | --- |
| Q-67 hold menu / edit | green (`QuickButtonEditTests`, 7) | hold /btw → menu → Edit → `/btw2` saved in place; All Slash Commands… opens the palette (0.35 s delay, so one dialog can follow another); Settings tap on built-in Y → Custom, purple kept | installed only; owner's thumb |
| Q-56..Q-66 | see the 2026-10-09 handoff | — | unchanged |

## Open threads

- **Push** `f02cb28` plus this handoff, on the owner's word only.
- **Q-67 limits:** prompt pills have no Edit (they are edited in the Prompts hub), and slash group pills (`/x…`) keep their Menu with no hold menu. The old `.contextMenu` in `slashPalette` is inert under the UIKit overlay; it was left in place.
- **CustomButtonForm preview** shows the default grey, not the slot's tint (this predates Q-67).
- Carried over from 2026-10-09: Slack draft to Jakob unsent; Kokoro daemon start not yet seen in `kokoro.log`; Q-57/Q-60 need a real push; Q-58 pin retest; owner calls on Q-50/51/52/54 and "restore buttons".

## 2026-10-12 addendum

- Memory check: `leaks` on the Mac app (2.5 days up) found 4.4 KB, all inside Apple's AppleScript `delay` (one NSTimer per call; the `delay`s in `KeystrokeInjector.swift` are load-bearing, left alone). Phone app on the simulator: 0 leaks after 24 UI loops and 6 reconnects, footprint flat at 56 to 57 MB. PTT and photo upload were not exercised.
