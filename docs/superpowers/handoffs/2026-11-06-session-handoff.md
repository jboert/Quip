# Session handoff, 2026-11-06 (evening): Q-91 Quip for Windows

**Resume:** "Continue Q-91 from docs/superpowers/handoffs/2026-11-06-session-handoff.md:
record the owner's PC test, then start S12 (release build) under the plan,
then the one review."

## Where it stands

Plan of record: `docs/superpowers/plans/2026-11-06-q91-windows-host.md`
(owner-approved, stop after S9 for a PC check). Spec:
`docs/superpowers/specs/2026-11-06-q91-quip-windows-host.md`. Board: Q-91.

- S1-S9 complete and pushed, each verified by the orchestrator (gate re-run)
  and, for Win32 slices, by Windows CI. Last green CI: run 42341224909 at
  `e6dea53` (Win32 UI tests: listing 6, displays 2, qr 2, tray 3; selftest 11/11).
- Read-only review of S4-S9 done: Needs fixes (0 high, 1 medium, 3 low). One low
  fixed directly (`df3e45f`). The rest is slice **R1**.
- R1 (review-fix) is complete and pushed (`db0699c`; Windows CI run 42343269299
  green: listing 6, displays 2, qr 2, tray 3, selftest 11/11). One more fix from
  the automated security review is pushed (`b009569`: evict a pre-auth socket only
  when it admits the sender). Windows CI on `b009569`: run 42343467201 green.
- The plan run is closed (Status line in the plan). S10-S12 (arrange, typing,
  release build) wait for the owner's PC check. Each starts as a fresh worker
  per the plan protocol; one review after the last slice of the next run.

## Specs built out (2026-11-07)

- Plan S10-S12 are now worker-ready (read set, steps, tests by layer, Mac
  parity, real-PC safety, acceptance, validation, risks); spec 5.2-5.5, 6, 8,
  9 and 11 filled where they had gaps.
- Test plan: `docs/superpowers/specs/2026-11-07-q91-windows-test-plan.md`
  (coverage matrix, known gaps, owner PC scripts per gate, release gate).
- Phase 2 (after S12, needs owner decisions in its section 6):
  `docs/superpowers/specs/2026-11-07-q91-windows-phase2.md`.

## Owner's PC test (2026-11-07)

`Quip.exe` built from `f30587c` (S10 arrange and S11 typing on top of R1;
Windows CI run 42456098622 green: win32_arrange 5/5, win32_input 10/10,
selftest 22/22) was sent to the owner on 2026-11-07, replacing the `f09f5b2`
build. SHA-256
`87880e381b859eccde320fd5f27acf846d1ac908a91817ecc497073cdb094bfb`.
S10 and S11 were started on the owner's "Proceed" before the PC check.

What works in this build: tray app, pairing (PIN or QR), Bonjour discovery,
the phone's grid of PC windows, phone pins and colours, arrange, minimize and
close, typing text and keys from the phone (PowerShell, cmd, Windows
Terminal), `--selftest` (22 cases). Typing into a window run as administrator
is refused on purpose ("is the window running as administrator?"): Windows
drops that input silently. Not yet: terminal text read-back.

Untested anywhere but the PC (owner check): focus when another app holds the
foreground lock, a non-elevated run (CI runs elevated), two monitors with
different scaling, an admin window next to a normal one.

Steps for the owner:
1. Copy `Quip.exe` to `%LOCALAPPDATA%\Programs\Quip\` and double-click it.
   SmartScreen: More info, then Run anyway (unsigned).
2. Windows Firewall prompt: allow on **Private** networks. If the home network
   is set to Public, the phone cannot connect.
3. Tray icon (bottom-right, maybe under the ^ arrow) -> Show pairing QR..., scan
   from the phone. Or wait for the PC to appear in the phone's connection list.
4. Open a PowerShell window: it should appear on the phone's grid. Type
   `Get-Date` from the phone and send: it should run. Tap Arrange on a
   Windows host only from a phone build that sends `arrange_windows` (1.5.7
   does not).
5. Selftest: in PowerShell, `& "$env:LOCALAPPDATA\Programs\Quip\Quip.exe" --selftest | Out-Host`.
   Send back the newest `%LOCALAPPDATA%\Quip\Logs\selftest-*.txt` (it holds no
   names or IPs).
6. If the phone cannot connect: on the PC run `netstat -an | findstr 8765`
   (expect `LISTENING`), and send `%LOCALAPPDATA%\Quip\Logs\websocket.log`.

Record the result in the plan's "Owner gates" and on the board before S10.

## Open items

- Q-92: the iOS suite cannot open its generated Xcode project on this Mac
  (Xcode 27.2). Every commit today used `QUIP_SKIP_CHECK=1` for that reason,
  with the suites that did run named in each message.
- Owner decision pending (told, not answered): rates of PIN guessing add up
  across IPv4 addresses (no all-senders guess cap, so the owner's right PIN is
  never refused). Spec 3.1 has the math.
- Possible follow-ups noted by workers: Bonjour is skipped if no LAN address
  exists at startup and is not retried; a plain `.ico` resource for Explorer
  (S12); the phone stores a Windows backend as kind `unknown` (phone-side,
  out of scope); phone 1.5.7 never sends `arrange_windows`.
- QA simulator clone `1CA3EE21-B289-4707-88DB-5E9940E82DD7` (Quip 1.5.7) was
  created for Q-91; keep it for S10/S11 QA, delete when Q-91 ends.
