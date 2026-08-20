# Session handoff — 2026-08-17

Branch: `eb-branch`, clean. Six commits, none pushed (`main` is protected; pushing
needs the owner's explicit go-ahead).

**Resume command for a fresh session:** read this file, then
`git log --oneline -6` and `docs/superpowers/board.md` — Ready holds §58
Iterations 1, 2, 4; Blocked holds Iteration 3's manual smoke.

## The theme of the day

All three reported problems were somewhere other than where they appeared. Two of
them were not code faults at all, and one had shipped-but-never-executed code.
The generalisable lesson is in the first entry: **check what is actually running
before reading source.**

## Commits

| Hash | Why |
| --- | --- |
| `1dbd64b` | Accepted sockets that never sent a WS upgrade lived forever; phone latency probes leaked one per alt URL per minute, and the peer's FIN_WAIT_2 RST ~60s later logged as a failed dial. `PreHandshakeReapPolicy`, 10s deadline. |
| `11dce93` | Session log: the multi-select "bug" was a Jun-20 binary; plus three backlog items corrected as already-shipped. |
| `58dd75e` | The phone never used LAN. Swap engine gated on an unset UserDefaults key (default-off = off for everyone), AND it compared TCP-connect probes against live WebSocket round-trips, so any candidate outscored the URL in use. |
| `6ec246c` | Recorded the LAN fix + the hardware-verification evidence table. |
| `0a1b206` | §58 Iteration 3: poll generation, coalescing, stale-result guards. `stopMonitoring` cancelled kqueue sources and an in-flight poll reinstalled them. |
| `585f3b4` | Marked Iteration 3 shipped, cleared both stale Blocked rows, refilled Ready. |

## Install state

| Target | Version | Note |
| --- | --- | --- |
| `/Applications/Quip.app` | built **Aug 17 12:47**, pid 50744 | Contains `1dbd64b`. Does **NOT** contain `0a1b206` (Iteration 3). |
| iPhone 17 Pro Max (`FA951BBB-D706-5FCF-9886-3E57560E9030`) | installed Aug 17 ~14:39 | Contains `58dd75e`. Verified running — LAN swap observed. |

The Mac app was **Jun 20** at session start, two months behind. That single fact
explained the entire multi-select complaint.

## Hardware-verified vs install-only

| Change | Status | Evidence |
| --- | --- | --- |
| Phone-driven multi-select | ✅ verified | `audit.log` `select_multi:1,2` at `20:40:45Z`; picks returned correct. First successful one on this machine. |
| Pre-handshake reaper | ✅ verified | `reaping … within 10s` at INFO against the phone's own probe; zero `broke during handshake` since; no leaked sockets. |
| LAN routing swap | ✅ verified | `client live: 192.168.4.42` at `21:57:02Z`; `netstat` showed `192.168.4.26.8765 ← 192.168.4.42`. Relay out of the path. |
| §58 Iteration 3 guards | ⚠️ tests only | 694 Mac tests green. Not installed, so the manual smoke (close tracked iTerm windows mid-poll) has not run. |

## Open threads

1. **Install the Mac build** carrying `0a1b206`, then run Iteration 3's smoke.
   Reinstall re-prompts Accessibility + Screen Recording and orphans the APNs
   `.p8` (re-enter in Settings → Notifications).
2. **§58 Iterations 1, 2, 4** — all need something from the owner: a
   multi-display smoke (1), a two-peer Mac+iOS install (2), a UX decision on the
   drag-to-resize promise (4).
3. **Push + PR.** Six commits sit local. `main` rejects direct pushes, so landing
   them needs `eb-branch` pushed and a PR opened — outward-facing, so it waits.
4. **LAN swap durability.** Verified once, on a foregrounded app. Worth
   confirming it re-swaps after a cold start and that it fails back sanely when
   the phone leaves Wi-Fi.

## Traps worth remembering

- `ditto` leaves the `.app` directory mtime alone — check
  `Contents/MacOS/Quip` or you will think an install failed.
- `strings | grep` does not find Swift symbols; use
  `nm -a … | grep -ci <symbol>` to prove a binary carries a feature.
- Three symptoms across unrelated code paths point at one stale binary, not
  three live bugs.
- "Default-off pending verification" can mean the feature never runs at all,
  because the verification needs it running. Check for other flags with this
  shape.
