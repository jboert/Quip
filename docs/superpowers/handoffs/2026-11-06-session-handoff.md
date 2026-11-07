# Session handoff, 2026-11-06: Q-91 Quip for Windows

## Where things stand

- Owner wants Quip on their Windows PC (x64 Intel, Windows 10/11, PowerShell).
  No Windows host existed. All work stays on `eb-branch`, pushed the same day
  (owner, 2026-11-06).
- Spec (tracked): `docs/superpowers/specs/2026-11-06-q91-quip-windows-host.md`.
  PRD (gitignored): `tasks/prd-quip-windows-host.md`. Board: Q-91.
- Owner asked for testing at the same bar as Mac/iOS and for every milestone to
  be independently reviewed and proven working. Spec sections 10 and 14 hold
  the plan: shared Swift/Rust vector files, a Rust twin per matching Mac test
  file, fake-platform integration tests, Win32 tests on CI + `--selftest` on
  the PC, `tools/fake-windows` for simulator QA, cargo-mutants, gate per
  milestone (check.sh, mutations, independent review, evidence, board, push).

## Commits this session

- `7671c8e` spec, phase 1 design
- `f51a718` spec, test plan + milestones and gates
- `ffeb81c` M0 spike `QuipWindows/spike/` (+ `.github/workflows/windows.yml`,
  runs on `windows-latest` for QuipWindows pushes on eb-branch; ci.yml only runs
  on main/PRs). Committed with `QUIP_SKIP_CHECK=1` because of Q-92.

## In flight when this was written

- M0: CI run of the spike on `windows-latest` (results decide 5.3/5.4 focus and
  multi-line method, and whether CI can host the Win32 UI tests). Owner has not
  run the spike on the PC yet: build with
  `cd QuipWindows/spike && cargo build --release --target x86_64-pc-windows-gnu`,
  copy `target/x86_64-pc-windows-gnu/release/quip-spike.exe` to the PC, run it
  in a PowerShell window, send back `%LOCALAPPDATA%\Quip\spike-report-*.txt`.
- M1: two builder agents (not committed when this was written):
  - Rust core in `QuipWindows/` (protocol, server, auth, router, pure rules,
    fake platform, `--fake-platform`, `tools/fake-windows/`).
  - Swift vector files + tests in `Shared/Tests/Fixtures/{wire,vectors}/`.
  Next: independent review of both, fix, wire Rust tests to the vectors, add
  scope `windows` to `changed-scopes.sh` + `check.sh`, simulator QA
  `tools/qa/q91-*.sh`, commit, push.

## Blockers / found along the way

- **Q-92**: the iOS suite cannot open its generated Xcode project on this Mac
  (Xcode 27.2, installed 2026-11-03): `"Models" is a member of more than one
  group` (first `.claude-flow`, a ruflo state folder). The committed pbxproj
  fails too. Blocks every iOS gate locally. Not started.
- Toolchain installed on the Mac this session: Rust target
  `x86_64-pc-windows-gnu`, `brew install mingw-w64` (14.0.0).

## Owner to do

1. Run `quip-spike.exe` on the PC and send the report (see above).
2. Later (M2): run `Quip.exe`, pair the phone, check the grid.
