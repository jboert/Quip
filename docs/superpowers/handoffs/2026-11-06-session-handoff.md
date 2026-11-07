# Session handoff, 2026-11-06: Q-91 Quip for Windows

**Resume:** "Continue Q-91 from docs/superpowers/handoffs/2026-11-06-session-handoff.md:
check M1 builder output in `QuipWindows/` and `Shared/Tests/Fixtures/`, run the
independent review, then commit and push M1."

## Goal

Owner wants Quip on their Windows PC (x64 Intel, PowerShell). No Windows host
existed. All work stays on `eb-branch`, pushed the same day (owner,
2026-11-06). Testing must be at the Mac/iOS bar, and every milestone must be
independently reviewed and proven working (owner, 2026-11-06).

- Spec (tracked): `docs/superpowers/specs/2026-11-06-q91-quip-windows-host.md`
  (sections 10 tests, 14 milestones + gates).
- PRD (gitignored): `tasks/prd-quip-windows-host.md`.
- Board: Q-91 (Windows host), Q-92 (iOS gate broken locally).

## Commits this session

| Hash | Why |
|---|---|
| `7671c8e` | Spec: phase 1 design, wire contract taken from the Mac (8-digit PIN, `deviceKind: windows` is harmless on the 1.6.0 phone). |
| `f51a718` | Spec: test plan at the Mac/iOS bar (shared vectors, Rust twin per Mac test file, fake-windows sim QA, CI + `--selftest`, mutations); milestones M0-M5 with gates; multi-line follows `MultiLineSendPolicy`. |
| `ffeb81c` | M0 spike `QuipWindows/spike/` + `.github/workflows/windows.yml` (runs on `windows-latest` for QuipWindows pushes on eb-branch); board Q-92. Hook skipped: iOS gate broken (Q-92); Mac suite 1369 green. |
| `0dcfa6f` | Spike starts classic console with `CREATE_NEW_CONSOLE` (conhost attached to the runner's console otherwise). Records first CI results. |
| this commit | This handoff. |

## M0 findings so far (CI `windows-latest`, build 26100, PS 5.1, PSReadLine 2.4.5)

- Interactive desktop on the runner: yes. Windows Terminal installed: yes.
- Windows Terminal + PowerShell: focus via plain `SetForegroundWindow`;
  `SendInput` unicode typing intact (accented, CJK, emoji).
- Multi-line: **Shift+Enter is safe** (nothing ran early; one Return ran both
  lines). **Clipboard paste is not** (Return ran only one of two lines). So
  spec 5.4 should pick Shift+Enter; record this when updating the spec.
- Classic console (conhost) not tested yet: first run failed to open windows;
  fixed in `0dcfa6f`, re-run (Windows workflow run 42319374974) was in flight
  when this was written. Check it with
  `gh run view 42319374974 -R jboert/Quip --log | grep -E "PASS |FAIL |RESULT "`.
- Focus has not yet been tested with another window in front (only one window
  opened in the first run). The re-run opens three.

## Uncommitted work in flight

Two builder agents were running when this was written. Their output is in the
working tree, **not committed, not reviewed**:

- Rust core in `QuipWindows/` (protocol, server, auth, router, pure rules,
  fake platform, `--fake-platform`) and `tools/fake-windows/`.
- Swift vector files + tests in `Shared/Tests/Fixtures/{wire,vectors}/`,
  `Shared/Tests/WireFixtureTests.swift`, `QuipMac/Tests/*Vector*`.

Next steps, in order:
1. `git status`; read what landed; run `cd QuipWindows && cargo test && cargo
   clippy --all-targets -- -D warnings && cargo check --target
   x86_64-pc-windows-gnu`, and the Mac suite for the Swift vectors.
2. Independent review (reviewer agent gets the diff + spec, not a summary).
   Fix findings.
3. Wire Rust tests to the vector files; add scope `windows` to
   `.github/scripts/changed-scopes.sh` (+ its test) and `tools/check.sh`.
4. `tools/qa/q91-*.sh` simulator scenarios against `--fake-platform`.
5. Commit M1 (mutation results + review answers in the message), push.

## Install state

| Where | State |
|---|---|
| Mac `/Applications/Quip.app` | 1.5.7 (build 1), installed 2026-10-27. Not updated this session (no QuipMac change). Repo is at 1.6.0 (`edf0438`). |
| iPhone | Not touched this session. |
| Windows PC | Nothing installed yet. |

## Verified vs not

| Item | State |
|---|---|
| Spike on CI Windows: WT focus, typing, unicode, Shift+Enter safe, paste unsafe | Verified on CI runner |
| Spike: classic console + focus with a window in front | CI re-run pending |
| Spike on the owner's PC | Not run |
| M1 Rust core, Swift vectors | Built by agents, not reviewed, not committed |

## Blockers found

- **Q-92**: iOS suite cannot open its generated Xcode project on this Mac
  (Xcode 27.2, installed 2026-11-03): `"Models" is a member of more than one
  group` (first `.claude-flow`, a ruflo state folder). Committed pbxproj fails
  too. Blocks every iOS gate locally; commits since use `QUIP_SKIP_CHECK=1`
  with the reason in the message.
- Toolchain installed this session: Rust target `x86_64-pc-windows-gnu`,
  `mingw-w64` 14.0.0 (Homebrew).

## Owner to do

1. Run the spike on the PC: on the Mac,
   `cd QuipWindows/spike && cargo build --release --target x86_64-pc-windows-gnu`,
   copy `target/x86_64-pc-windows-gnu/release/quip-spike.exe` to the PC, run it
   from PowerShell, send back `%LOCALAPPDATA%\Quip\spike-report-*.txt`.
2. Later (M2): run `Quip.exe`, pair the phone, check the grid.
