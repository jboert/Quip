# Hardware acceptance tests — the 2026-10-27 batch

Eight tickets were built and installed today with green unit suites and no
pass on real hardware: the VibeCut batch Q-79 to Q-84 (Codex session), the
enabled-windows-survive-a-relaunch fix `baee33d` and the build-number stamp
`f3ef01a`/`0038c48` (this session). This document is the test spec: what
each ticket claims, how to prove it on the real Mac and the real iPhone,
what evidence counts, and who runs it.

## Intent

A unit suite proves the code does what its author meant. These tests prove
the owner sees it: on `/Applications/Quip.app` (currently `75838b5`) and the
iPhone (currently `f3ef01a`, build 1641), with the real VibeCut checkout at
`~/Projects/vibecut`, real iTerm2 windows and the real Wi-Fi/Tailscale paths.
A ticket moves to "verified" on the board only with the evidence named here.

## Roles and order

- **Agent-run** (an agent session on the Mac, no phone needed): log-based and
  Mac-UI checks, and simulator passes against the real Mac where the test
  does not depend on the phone's hardware. Run first.
- **Owner-run** (needs the iPhone in hand): sequenced last, one sitting, with
  the agent tailing `~/Library/Logs/Quip/*.log` live during it.

Order: A1 Q-81 → A2 Q-82 → A3 Q-79 → A4 enabled windows → A5 build number →
A6 Q-84 Mac half → O1 Q-80 → O2 Q-84 phone half → O3 Q-83 → O4 build number
on phone → O5 enabled windows on phone.

## Ground rules

- Never edit the owner's real `~/Projects/vibecut`. Tests that need an odd
  catalog point the Mac at a copy via the `vibecutRepoPath` UserDefaults
  override (`defaults write com.quip.mac vibecutRepoPath <copy>`), and delete
  the key afterwards (`defaults delete com.quip.mac vibecutRepoPath`).
- The Mac app must be restarted after changing that key only if the reader
  caches the root; verify by watching the Prompts pane, do not assume.
- A sync is triggered from Quip → Settings → Prompts → Sync Now. Its
  outcome line is under "Last sync".
- Every phone step: the agent runs `tail -F` on `websocket.log`,
  `latency.log`, `injection.log`, `phone.log` before the owner starts.
- No test may leave state behind: synced fixture prompts are removed by a
  final sync against the real root; the `vibecutRepoPath` key is deleted;
  simulator pairing is torn down.

## Current blockers found while writing this

- **Q-83 cannot run yet.** The private store is read from
  `~/Projects/vibecut/private/projects.json` and that directory does not
  exist on this Mac. Either VibeCut has not written it or the path differs.
  Confirm with the VibeCut side before O3; until then Q-83 stays "built".
- **Q-79's map file does not exist yet** (`~/Library/Application
  Support/Quip/vibecut-ids.json`): no sync has run since the build. A3 starts
  by creating it with one sync.
- **Q-82 reads "Unknown"** for any sync from before its build. A2's first
  Sync Now clears that.
- The real catalog is `version 3.0` with 51 prompts; Q-81 needs a copy with
  the version bumped.

---

## A1 — Q-81: an unknown VibeCut schema is refused, not half-read

Claim: a catalog whose `version` major is above 3 fails the sync with
"VibeCut catalog version X is newer than this Quip understands" and leaves
the inherited set untouched; a pack whose `format` is not `vibecutpack/1`
counts as an unreadable pack.

Preconditions: one good sync against the real root (so there is an inherited
set to protect). Note the prompt count the Prompts pane reports.

Steps:
1. `cp -R ~/Projects/vibecut <scratch>/vibecut-v4`; in the copy set
   `shared/prompts.json` `"version": "4.0"`.
2. `defaults write com.quip.mac vibecutRepoPath <scratch>/vibecut-v4`.
3. Settings → Prompts → Sync Now.
4. Restore: real root in a second copy with one pack's `format` set to
   `vibecutpack/9`; repeat steps 2 and 3.
5. `defaults delete com.quip.mac vibecutRepoPath`; Sync Now against the real
   root.

Expected: step 3 shows the "newer than this Quip understands" line under
Last sync and the inherited prompt count is unchanged on Mac and phone. Step
4 syncs, and the outcome line counts one skipped pack. Step 5 is a clean
sync with the original count.

Evidence: screenshot of the Last sync line after step 3 and 4; prompt count
before/after from the Prompts pane.

Runner: agent.

## A2 — Q-82: Settings says whether VibeCut changed since the last sync

Claim: after a sync the pane shows Current; editing any VibeCut source
(catalog, fragments, organization, a pack, an editor save) flips it to
"VibeCut changed since this sync — Sync Now to update"; a sync from before
this build shows Unknown.

Steps:
1. Open Settings → Prompts. Record what the line says before any sync
   (expected: Unknown or Never synced).
2. Sync Now. Expect Current.
3. Touch a source without changing content: `touch
   ~/Projects/vibecut/shared/prompts.json`. Expect still Current (the
   fingerprint is by bytes, not mtime).
4. Point at a copy (A1 method) whose `fragments` file has one added
   character. Expect the "changed since this sync" line without syncing.
5. Sync Now. Expect Current. Delete the override, Sync Now, expect Current.

Evidence: the pane line at each step.

Runner: agent.

## A3 — Q-79: inherited prompt ids survive a rename in VibeCut

Claim: a prompt renamed in VibeCut keeps its Quip id, so the phone keeps its
hide state, project tags and usage ranking.

Steps:
1. Sync Now against the real root. Confirm
   `~/Library/Application Support/Quip/vibecut-ids.json` now exists and
   maps every source id to a `vibecut__<slug>` id. Pick one prompt P and note
   its Quip id.
2. On the phone (owner, or simulator paired to the real Mac): hide P, or tag
   it with a project. Confirm the phone shows it hidden/tagged.
3. In a copy of the root, rename P (change its `name`, keep its source id).
   Point the Mac at the copy, Sync Now.
4. Expected: the map still gives P's source id the same Quip id; the phone
   still shows P (under the new name) hidden/tagged. No new prompt appeared.
5. Restore the override, Sync Now.

Evidence: `vibecut-ids.json` before and after step 3 (same id for P's source
id); phone prompt list before and after.

Runner: agent for steps 1, 3, 5; phone half can be the simulator.

## A4 — enabled windows survive a Quip relaunch (`baee33d`)

Claim: with "Mirror desktop terminals" off, a window the owner enabled is
still enabled after Quip quits and relaunches, within one boot.

Steps:
1. Settings → General → Phone: Mirror desktop terminals OFF.
2. In Quip's window list enable exactly two iTerm2 windows. Phone grid shows
   those two.
3. `pkill -KILL -f /Applications/Quip.app/Contents/MacOS/Quip`; `open
   /Applications/Quip.app`; wait for the phone to reconnect
   (`websocket.log`: `client live`).
4. Expected: the same two windows enabled on the Mac list; phone grid shows
   the same two, not "No windows".
5. `defaults read com.quip.mac windowEnabledIDs` lists the two ids;
   `windowEnabledIDsBoot` equals `sysctl -n kern.boottime` seconds.
6. Disable one, relaunch again: only the other comes back.

Evidence: `defaults read` output; phone grid before/after (owner or
simulator).

Runner: agent (Mac half + simulator); owner confirms on the phone in O5.

## A5 — the version row shows a build number (`f3ef01a`, `0038c48`)

Claim: Settings version row reads `1.5.7 (<count>, <hash>, <date>)`; the
menu bar reads `1.5.7 (<count>) <hash>`; a build that cannot name its commit
fails instead of saying "unknown".

Steps:
1. Phone: force-quit, reopen, Settings → Version row. Expected
   `1.5.7 (1641, f3ef01a, 2026-10-27 19:42)` (the installed build).
2. Mac: not yet installed with this change; expected still
   `1.5.7 (75838b5, 2026-10-27 19:07)` in Settings. After the next Mac
   install the row gains the count and the menu bar shows `1.5.7 (N) <hash>`.
3. Agent: `tools/stamp-build-info.sh` with `SRCROOT` pointing at a dir
   without `.git` exits 1 with the `error:` line; with
   `QUIP_BUILD_COMMIT=abc1234` it stamps; with `QUIP_ALLOW_UNSTAMPED=1` it
   stamps `unknown`. (Already probed 2026-10-27 19:55; re-run after any edit.)

Evidence: phone screenshot of the row; Mac Settings screenshot; script
output.

Runner: agent for 2 and 3; owner for 1 (O4).

## A6 — Q-84 Mac half: windows carry their project

Claim: `WindowState.project` is the git-root folder name of the window's cwd.

Steps:
1. Open three iTerm2 windows: one cd'd into `~/Projects/Quip`, one into a
   subfolder of a git repo (e.g. `~/Projects/Quip/QuipMac`), one into a
   folder with no git root (e.g. `~/Downloads`).
2. Read the layout the Mac sends. Cheapest: the simulator paired to the real
   Mac, or `websocket.log` if layouts are logged; otherwise a one-off
   `tools/fake-mac`-style client is NOT valid here because the Mac is the
   side under test. Use the simulator.
3. Expected: `project` = `Quip`, `Quip`, and for the third either nil or the
   folder name per `ProjectName.resolve` (basename when no `.git` above
   it). Record what it actually sends for the third.

Evidence: the three project values as the phone/simulator shows them in the
window cards or Prompts hub grouping.

Runner: agent with simulator.

---

## O1 — Q-80: "Make my own copy" of an inherited prompt

Claim: editing a VibeCut-inherited prompt on the phone offers Make my own
copy; the copy has a non-`vibecut__` id, no `vibecut` tag, keeps project /
purpose / needs tags, and survives the next sync; the original is untouched.

Steps:
1. Phone: Settings → Prompts → open an inherited prompt P → editor shows the
   VibeCut note and a "Make my own copy" button.
2. Change the text, tap Make my own copy.
3. Expected: a new prompt appears next to P with the edited text; P still
   has the original text.
4. Mac: Sync Now. Phone: the copy still exists with the edited text; P
   unchanged.
5. Delete the copy. P remains.

Evidence: phone screenshots after 3 and 4; the Mac's
`~/Library/Application Support/Quip/prompts/` has no new `vibecut__` file.

Runner: owner (simulator can pre-run it, owner confirms).

## O2 — Q-84 phone half: project prompts listed by the selected window

Claim: the phone's selected project is `project ?? folder`; the Prompts hub
lists project-tagged prompts under the selected window's project.

Steps:
1. Tag one prompt with `project:Quip` on the phone.
2. Select the `~/Projects/Quip` window → Prompts hub shows it in the project
   group. Select the `~/Downloads` window → it does not.

Evidence: two screenshots.

Runner: owner.

## O3 — Q-83: VibeCut private project prompts stay local-only

Blocked until `~/Projects/vibecut/private/projects.json` exists (see
blockers). When it does:

Claim: store prompts arrive tagged `project:<name>` and `local-only`; a
tunnel client never receives them and cannot paste, put or delete them; the
iCloud preferences copy drops their usage, pinned slots and slot colors.

Steps:
1. Sync Now. Phone on LAN/Tailscale: the store prompts appear with both
   tags; their ids are the store's opaque ids.
2. Phone on cellular via the Cloudflare tunnel URL: the prompt library has
   no local-only prompts; attempting to paste one by id (quick button bound
   to it) is refused with an attributed failure on the phone.
3. Re-sync after VibeCut changes a `project:` assignment: VibeCut's tag
   wins over a hand-added one.

Evidence: prompt list on LAN vs tunnel; `websocket.log` line for the refused
paste; the prompt file's tags.

Runner: owner, agent tailing.

## O4 — build number on the phone

Steps: A5 step 1. Evidence: screenshot. Runner: owner.

## O5 — enabled windows on the phone

Steps: A4 steps 1–4 with the owner watching the phone grid instead of the
simulator. Evidence: the grid after relaunch. Runner: owner.

---

## Results

| Test | Ticket | Runner | Result | Evidence | Date |
|---|---|---|---|---|---|
| A1 | Q-81 | agent | not run | | |
| A2 | Q-82 | agent | not run | | |
| A3 | Q-79 | agent | not run | | |
| A4 | baee33d | agent | not run | | |
| A5 | f3ef01a | agent | script probe passed 19:55; phone/Mac rows not run | this doc, commit `0038c48` | 2026-10-27 |
| A6 | Q-84 | agent | not run | | |
| O1 | Q-80 | owner | not run | | |
| O2 | Q-84 | owner | not run | | |
| O3 | Q-83 | owner | blocked: no private store on disk | | |
| O4 | f3ef01a | owner | not run | | |
| O5 | baee33d | owner | not run | | |

Quick buttons after reinstall (not a ticket): verified 2026-10-27 19:20–19:21,
three `send_text … success=1` lines in `latency.log`.

## What is left to the runner

- Whether the Mac caches `vibecutRepoPath` (restart or not): find out in A1.
- The exact wording of the skipped-pack count line in A1 step 4.
- What `project` the Mac sends for a window with no git root (A6 step 3).
- Whether a simulator pass is accepted for the phone halves of A3/A4/O1, or
  the owner wants the iPhone for all of them.
