# Session handoff — 2026-08-20

Branch: `eb-branch`, clean. **Nineteen commits ahead of `origin/eb-branch`, none
pushed.** `main` is protected; landing needs a PR, and both the push and the PR
are the owner's call.

**Resume:** read this file, then `git log --oneline -6` and
`docs/superpowers/board.md`. The Ready column has four manual smokes left, all
unblocked and all needing hands on hardware — start by asking which one the
owner wants rather than looking for code to write.

## What shipped

| Hash | Why |
| --- | --- |
| `9f0c525` | Q-20a measured on hardware and recorded as a **failure**, not a pass. Root cause found and refiled as Q-21. Also moved Q-16/Q-17a/Q-18a/Q-19b out of Blocked — they were waiting only on the Mac install, which is now done. |
| `7611d32` | **Q-21.** A network-blocked agent no longer badges the phone as a prompt. `PaneStability` + `PromptRaiseGate` + detector wiring. |
| `2263d69` | Q-21a confirmed on hardware — raises 67 → 10 in the same 180s protocol. |
| `0d33552` | Session log: why the flap survived Q-20 and why the obvious fix is a dead end. |

Suites at the end: harness 62 checks, **QuipMac 752 tests**, QuipiOS 770 tests,
all green through the pre-commit gate.

## The one finding worth carrying forward

**The terminal flap was never a timing problem.**
`TerminalStateDetector.swift:515` decides the state with `totalCPU <
cpuThreshold` over the AI child processes alone, and an agent blocked on an LLM
stream or an MCP call burns ~0% CPU — so it is *identical* to a prompt waiting
on a human. Q-20's debounce made the required quiet run longer, which only
delays the same wrong answer. Measured proof: every raise cleared again after
1-5s, and a real prompt idles indefinitely.

**And the obvious fix is a trap.** "Read the pane and look for the prompt" does
not work — **Claude Code draws its `❯` input box while it is working too**
(verified against live panes). Both states also show a glyph plus an elapsed
time: `✶ Crystallizing… (40s · ↓ 1.4k tokens)` working, `✻ Cooked for 23m 34s`
idle. The design was approved on an input-cue rule and had to be changed
mid-build once the captures falsified it.

What separates them is **movement**: a working agent redraws a live counter every
frame, an idle one is frozen (same pane read three times a second apart came back
byte-identical). So the raise — and only the raise — captures the pane twice
400ms apart and proceeds only if nothing moved. No agent dialect is baked in,
which matters because the status verbs are randomized per turn.

`prompt-gate skipped` in `push.log` means the pane could not be read and that
window fell back to CPU alone. That is the **fail-open path, not a pass**.

## Install state

| Target | Version | Note |
| --- | --- | --- |
| `/Applications/Quip.app` | pid **76082**, started Aug 19 17:30 | Carries `7611d32`. `nm` finds 18 `PaneStability`/`PromptRaiseGate` symbols. Only `/Applications/Quip.app` on disk — stale build copies unregistered and deleted. |
| iPhone 17 Pro Max | installed Aug 19 ~16:53 | Carries `316f483`-era iOS code plus the Q-21 Shared/ additions. Connected over Tailscale at last check. |

## Verified vs not

| Change | Status |
| --- | --- |
| Q-21 prompt gate | ✅ tests (14 new) **and** hardware: 67 raises → 10, worst window 44 → 1, **zero** fail-open skips |
| A real prompt still badges within ~2s | ❌ unit oracle only; not confirmed on the phone grid |
| Q-19b / Q-18a / Q-16 / Q-17a | ❌ still not run — all unblocked, all need hands |
| Q-18a multi-display half | ❌ unrunnable, one display on this machine |
| APNs push | ❌ **dark all session.** `push.log` logged `APNs not configured` throughout, including after the `.p8` was re-entered. Quip was reinstalled twice afterwards, and every stable-resign reinstall re-triggers the keychain-orphan pattern — the key needs re-importing through Settings, not just re-typing. |

## Open thread: "Codex inputs not working on mobile"

Investigated at length; **not reproduced**, and two hypotheses were falsified.
Ruled out, with evidence:

- Connection/auth — `client live: 100.72.13.19:61613 (auth=pin)`
- Taps never reaching the Mac — both sends are in `audit.log`
- Misclassification — logged `cli=codex`, `path=pasteText`
- Codex refusing input at an `Action Required` prompt — **falsified**, that exact
  state was reproduced and "Proceed" approved the command
- Cmd+V landing in the wrong app when iTerm is not frontmost — **falsified**,
  worked with Finder frontmost

The failure moment (`latency.log`): two sends to the Codex window at 16:18:54Z
and 16:18:57Z, `success=1` both, then "Proceed" to two *Claude* windows at
16:21:07/16:21:21 and six `press_return` in four seconds — the shape of someone
retrying and giving up.

The only measurable difference from six passing reproductions is timing:
`inject_ms=2519` and `4711` on the failing sends versus `424–615` on every
passing one. `success=1` is written after the AppleScript returns, so a paste
slow enough to race Codex's redraw would still log success. **Stated as the open
lead, not a finding.**

Two proposals, neither actioned:
1. Instrument the Codex paste path — read the pane before and after the paste and
   log whether the text actually appeared, so `success=1` means "Codex has it".
2. Keep the phone emulator. A ~50-line Node client that authenticates and drives
   `send_text`/`quick_action` exactly as the phone does; it is what made this
   bisectable. Currently in the session scratchpad only — it will be lost unless
   moved into `tools/`.

Next occurrence, the highest-value capture is the **window title and whether the
text appears in Codex's composer**, which splits "never arrived" from "arrived
but not accepted" — the one split the logs could not make.

## Traps confirmed again today

- `xcodegen generate` before **every** build; restore `project.pbxproj` after.
- Mac tests need Quip quit first (the test host binds 8765), which drops the
  phone — say so before running them.
- `pgrep -fl codex` false-positives on `codex.system` in `PATH`; Codex CLI runs
  under a `node` comm. Match on `comm`, not args.
- iTerm's AppleScript `close` can return success without closing (same behaviour
  noted against Q-16).
- A window must be **enabled** to be addressable from a client;
  `windowsForBroadcast` publishes only enabled windows.

## Open threads for the owner

1. **Re-import the APNs `.p8`** — push has been dark all session.
2. **Four smokes need hands:** Q-17a, Q-19b, Q-16, Q-18a (runnable half).
3. **Nineteen commits sit local.** Push and PR both need explicit approval and
   have not been requested.
