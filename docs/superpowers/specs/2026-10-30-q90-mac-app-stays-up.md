# Spec: The Mac app stays up, and the phone gets you back in when it doesn't — Q-90

Status: **spec only, no code**. Written 2026-10-30, revised the same day ("improve", "make it work intelligently and intuitively").
Platform: QuipiOS stories first (no Mac rebuild, useful the day they ship), then QuipMac stories together (one Mac rebuild, owner at the Mac for the TCC re-grants). Remote access is Tailscale only (no tunnel, owner 2026-10-28).

## 1. Why

Owner, 2026-10-30: "if I'm mobile and remote and all of a sudden the desktop app is turned off or crashes, which does happen frequently … how do I ensure this will still work? Is there an easy way to restart the app on the remote device?" Then: "don't let it keep crashing", "healthy quip is good", "make it work intelligently and intuitively".

When Quip on the Mac is gone, the phone has nothing to talk to. Three layers, cheapest for the owner first:

1. **The Mac brings Quip back by itself** after a crash, a hang or a stray quit, within about a minute, and stops trying when it is clearly broken.
2. **The phone tells the truth in plain words**: "restarting, usually under a minute", "your Mac is offline", "Quip stopped after crashing 3 times". Each comes with the one action that helps.
3. **One tap in** (Screen Sharing over Tailscale, which runs without Quip) for whatever is left.

And every restart leaves its cause behind, so restarts get rarer: the net is not the fix.

### What "intuitive" means here

- **Nothing to set up.** On by default; a fresh install is protected without opening Settings.
- **The phone never says "Unreachable" alone.** It says what is down, what the Mac is doing about it, and the next step.
- **No false alarms.** Sleep, App Nap, an install, or a slow launch never count as a hang or a crash.
- **Know before you leave.** The phone shows whether the Mac is protected while it is still connected.

## 2. What the code does today (checked 2026-10-30 at `28883ae`)

| Area | Today | Where |
|---|---|---|
| Crash restart | Opt-in LaunchAgent `com.quip.QuipMac.crash-recovery`: `KeepAlive {Crashed: true, SuccessfulExit: false}`, `RunAtLoad`, `ThrottleInterval 30`, execs `Contents/MacOS/Quip` | `QuipMac/Services/CrashRecoveryAgent.swift`; toggle in Settings → General → Reliability |
| Two launchers | The login item (LaunchServices) and the agent (raw exec) both start Quip at login; the loser of the `flock` race **exits 0** so launchd does not loop | `QuipMac/Services/SingleInstanceGuard.swift`, `QuipMacApp.swift` ~397 |
| **The gap** | On the owner's Mac now: agent installed, `state = not running, runs = 1, last exit code = 0`, while Quip runs from a manual open. The agent's copy lost the race, exited 0, and launchd will not start it again. **The running Quip is unsupervised.** Every install does the same (the recipe relaunches with `open`) | `launchctl print gui/501/com.quip.QuipMac.crash-recovery` |
| Hangs | Not covered. Quip's "crashes" have mostly been hangs (blocking call on the main actor); `KeepAlive.Crashed` never fires for a hang | memory quip-hangs-not-crashes; `/Library/Logs/DiagnosticReports/Quip_*.hang` |
| App Nap | **No opt-out** (no `beginActivity`, no `NSAppSleepDisabled`). A menu-bar app with no visible window can be napped: timers stretch. A heartbeat timer would look stale on a healthy Quip | `grep -r beginActivity QuipMac` → none |
| Screen Sharing | On (`com.apple.screensharing` active). Works with Quip dead | macOS |
| Mac sleep | `sleep 0` on the owner's Mac (Amphetamine/caffeinate); other users' Macs may sleep | `pmset -g` |
| Known crash causes | Hangs on the main actor; SIGABRT in log writes on a full disk (fixed `99927a4`) | memories |
| Phone when Quip is gone | "Unreachable" on the backend row, silent backoff reconnect; Remote in only from the Backends long-press (US-011) | `BackendPickerSheet.swift` |

## 3. Behaviour in one table

What the Mac does, and what the phone says, for each way Quip goes away.

| Event | Mac | Phone (while down) | Phone (when back) |
|---|---|---|---|
| Crash | launchd relaunches in ≤ 30 s | "Quip on your Mac stopped. Restarting… usually under a minute" + spinner | toast "Quip restarted after a crash · Details" |
| Hang (no heartbeat 60 s, twice) | watchdog samples, `kill -9`, launchd relaunches | same as crash (it cannot tell yet) | toast "…after it froze" |
| Stray quit (menu, `osascript`, Activity Monitor) | relaunched like a crash (§6.1) | same | toast "…after it was quit" |
| **Stop Quip…** from the menu | stays stopped on purpose | "Quip was stopped on your Mac" + **Remote in** | — |
| 3 restarts in 10 min | crash-loop stop: agent booted out, one retry after 30 min | "Quip keeps crashing on your Mac — stopped restarting" + **Remote in** | toast + Mac banner with the cause |
| Disk full | no restart (it would only crash again); reason `disk_full` | "Your Mac's disk is full — Quip can't run" + **Remote in** | — |
| Mac offline / asleep / phone's Tailscale off | — | "Can't reach your Mac" + **Check Tailscale** (opens the Tailscale app) | normal reconnect |
| Protection off or not watching | — | (while still connected) Settings → Mac row: "Auto-restart is off — turn on" | — |

## 4. Stories

### Phone first (no Mac rebuild)

#### US-001: Say what is down, in plain words
- [ ] When the active Mac has been unreachable for 15 s, probe its host on TCP **5900** (Screen Sharing) with a 3 s timeout, at most once per 60 s, socket closed on every path (cf. the probe leak, `1dbd64b`).
  - 5900 answers → Mac is up, Quip is down.
  - Neither answers → Mac offline, asleep, or Tailscale off on either side.
- [ ] One banner over the grid (not a modal), using the table in §3. Before the Mac stories ship, "Quip is down" reads "Quip isn't running on your Mac" (no restart promise, since the phone cannot know the Mac is protected).
- [ ] The banner goes away by itself the moment the socket is back; no tap needed.
- [ ] **Check Tailscale** opens the Tailscale app (`tailscale://`, added to `LSApplicationQueriesSchemes`), the fix for the 2026-10-30 outage.
- [ ] `phone.log`: `mac_down kind=quip_down|offline probe_ms=N` on change only; never the host.
- [ ] Pure `MacDownClassifier.classify(quipPort:screenSharing:reliability:) -> MacDown` + table tests (every §3 row the phone can reach).

#### US-002: One tap in from the banner
- [ ] The banner carries **Remote in** (Q-88 US-010/011 setting, no window step). No host set → **Set up Remote in** (opens the setting).
- [ ] Shown at once for "stopped" states; for "restarting" it appears after 90 s (by then the restart has failed), so the owner is not pushed into Screen Sharing for a 30 s blip.
- [ ] Sim scenario `tools/qa/q90-down.sh`: fake Mac `dead` → banner within 20 s; with a local listener on 5900 → "Quip isn't running"; tap → `remote_in … result=no_app` on the sim; fake Mac `alive` → banner gone.

### Mac (build together, one rebuild)

#### US-003: launchd always owns the running Quip
- [ ] Quip started **not** by the agent (`XPC_SERVICE_NAME` ≠ label) while the agent is installed → `launchctl kickstart gui/<uid>/<label>` and exit 0 **before** the instance lock. The agent's copy starts and is supervised. Kickstart fails → log and keep running (fail open, like the lock).
- [ ] With `KeepAlive true` (§6.1), a single-instance loser that slipped through is relaunched after 30 s and wins once the other copy is gone: self-healing, not a loop.
- [ ] The login item is dropped while the agent is on (`RunAtLoad` covers login) and restored when it is off.
- [ ] Menu-bar **Quit** becomes **Stop Quip…**: confirm ("Quip won't restart until you open it again or log in"), `launchctl bootout`, exit. Opening Quip re-bootstraps the agent.
- [ ] **Installs never look like crashes**: the install recipe (and any future updater) runs `bootout` → `ditto` → `bootstrap`, and writes an `installing` marker the watchdog honours for 5 min. Recipe doc + `reference_quip_install_recipe` memory updated.
- [ ] Pure `LaunchOwnership.decide(agentInstalled:launchedByAgent:) -> .run | .handOff` + tests.

#### US-004: A hung Quip is restarted, with no false alarms
- [ ] Quip opts out of App Nap for its lifetime (`ProcessInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Quip serves the phone")`), so its timers keep time while it has no window.
- [ ] Heartbeat: Quip writes Unix time to `~/Library/Application Support/Quip/heartbeat` every 10 s **from the main actor**.
- [ ] Watchdog LaunchAgent `com.quip.QuipMac.watchdog` (`StartInterval 30`, `/bin/sh` on a script in the bundle: no TCC, no new binary). Kill only when **all** hold:
  - the heartbeat is older than 60 s on **two consecutive checks**;
  - Quip has been up more than 120 s;
  - the watchdog's own previous check was less than 90 s ago (a longer gap means the Mac slept; skip one round);
  - no `installing` marker younger than 5 min.
- [ ] Then `sample <pid> 3` → `~/Library/Logs/Quip/hang-<time>.txt` → `kill -9` (Quip traps SIGTERM), so the crash agent restarts it.
- [ ] The decision is one pure shell function, tested by `tools/check.sh`'s harness with fixed inputs (each guard above, both sides).

#### US-005: Don't let it keep crashing
- [ ] The watchdog keeps the last restarts in `~/Library/Application Support/Quip/restarts.json` (time, reason, top frame).
- [ ] **3 restarts in 10 min → stop**: `bootout` the crash agent, leave Quip down, marker `stoppedForCrashLoop`. It lives in the watchdog, so it works even when Quip dies before its own code runs.
- [ ] **One more try after 30 min** (a cause may have passed: a disk freed, a network share back). A 4th crash stops it until the owner opens Quip.
- [ ] **Disk full** (`df` free < 500 MB on the home volume) → no restart at all, reason `disk_full`; resumes by itself when space is back.
- [ ] `watchdog.log`: one line per action (`crash_loop restarts=3 window=10m action=stopped retry_at=…`), throttled `ok` every 30 min.

#### US-006: The phone knows the Mac's protection, before and after
- [ ] New message `reliability_status {watching: Bool, afterQuit: Bool, watchdog: Bool, lastRestart: {reason, at}?}` sent after auth and on change (`Shared/MessageProtocol.swift`; an older phone ignores it). The phone keeps the last one per Mac, so it still knows while the Mac is down; that is what lets US-001 say "Restarting…" instead of guessing.
- [ ] Phone Settings → Mac row shows **Auto-restart: on** or, in orange, **Auto-restart is off / not watching — Turn on** (sends a request; the Mac installs the agents). The owner sees it at home, before leaving.
- [ ] After a restart, the first auth carries `lastRestart`; the phone toasts "Quip on your Mac restarted after a crash (2:04 pm) · Details" once. `phone.log`: `mac_restarted reason=…`.

#### US-007: Every restart is a bug to fix
Restarting is the net; a healthy Quip is the goal.
- [ ] Mac Settings → Reliability lists the last 5 restarts: time, reason, and the **top three Quip frames** (from the `.ips`, or the watchdog's `sample` for a hang). **Same cause 3 times** is marked as such: one bug, not three.
- [ ] **Copy for a ticket** per row: frames, build commit, uptime, reason; no home paths, no window titles.
- [ ] The Diagnostics bundle (phone → Request Mac bundle) adds `watchdog.log`, `restarts.json` and the last 3 `hang-*.txt`.
- [ ] After a crash-loop stop, the first manual launch shows a one-time Mac banner ("Quip was stopped after 3 crashes in 10 minutes") with the frames.

## 5. Settings

Mac Settings → General → Reliability, all on by default:

- **Keep Quip running**: the one switch most people see. On installs both agents; a fresh install turns it on at first launch, and an existing install turns it on once (migration flag), because off is exactly the case this spec is for.
- *Advanced* (disclosure, collapsed):
  - **Restart after Quit**: off = Quit works as today (`KeepAlive {Crashed: true, SuccessfulExit: false}`, menu says Quit).
  - **Restart a frozen Quip**: the watchdog.
- Status line under the switch, plain words: "Watching Quip · restarted once today (crash)" / "Not watching — Fix".
- Not settings: the 60 s hang threshold, the 3-in-10-min stop, the 30 min retry. Wrong values either kill a healthy Quip or lock the owner out, and nobody can judge them from a settings screen. They are constants, tuned from `watchdog.log`.
- Pure `ReliabilitySettings.agents(keepRunning:afterQuit:frozen:) -> (keepAlive:, watchdog:)` + tests.

## 6. Decisions (owner, 2026-10-30)

1. **Any exit comes back** unless the owner chose **Stop Quip…**. From the phone, an accidental quit and a crash look the same: locked out.
2. **Hang threshold 60 s** (two checks, so 60–90 s). Worst case down ≈ 2 min. A healthy Quip never blocks its main thread for 60 s.
3. **Settings optional, on by default**, few, plain (§5).
4. **Stop a crash loop** after 3 in 10 min, one retry after 30 min (§US-005).

## 7. Non-goals (v1)

- Restart from the phone without Screen Sharing (Tailscale SSH + `launchctl kickstart`): one tap, but it needs Tailscale SSH on and an SSH identity on the phone. Revisit if the Mac-side restarts are not enough.
- Waking a sleeping Mac (Wake-on-LAN does not cross Tailscale). The phone says "Can't reach your Mac"; it does not claim to know why.
- A separate Quip daemon. launchd is the supervisor; the watchdog is a 30 s shell check.

## 8. Checks

- Unit: `MacDownClassifier` (every §3 row), `LaunchOwnership`, `ReliabilitySettings`, the watchdog function (each guard both sides: age 59/61 s; one stale check vs two; uptime 100/130 s; check gap 60/120 s; installing marker 4/6 min; restarts 2/3 in 10 min; retry at 29/31 min; disk 400 MB/1 GB), clean-shutdown and restart reasons.
- Mutation check per pure type; results in the commit message.
- Sim: `tools/qa/q90-down.sh` (US-002).
- Mac hardware check (owner present, after the one rebuild):
  1. `launchctl print gui/501/com.quip.QuipMac.crash-recovery` → `running`, Quip's pid. Keystroke injection still works in the agent-started copy (Accessibility follows the bundle).
  2. `kill -9 <pid>` → back within 30 s; the phone shows "Restarting…" then the toast.
  3. `kill -STOP <pid>` → sampled and killed within 90 s, back within 30 s more; toast "…after it froze".
  4. Close the lid / sleep 5 min on a test Mac, wake → **no** kill (`watchdog.log` shows the skipped round).
  5. Run the install recipe → no restart counted, no crash-loop stop.
  6. `kill -9` three times within 10 min → stopped; the phone says "keeps crashing"; 30 min later one retry.
  7. Menu → Stop Quip… → stays stopped; the phone says "Quip was stopped". Open Quip → protected again.
- Phone hardware check (remote, on cellular): Mac row shows "Auto-restart: on"; quit Quip on the Mac → "Restarting…" → back on its own; Stop Quip… → **Remote in** → Screen Sharing → open Quip → the phone reconnects and the banner goes away.

## 9. As built (2026-10-31)

Phone: merged `df5ff35` (Ralph run). Mac: `474cf00` (watchdog restart reasons), `f9ee248` (wiring), installed with `tools/install-mac.sh`.

Differences from the stories above:
- No login item to drop: the "Launch at login" switch was never wired; the agent's `RunAtLoad` is the login launch.
- The watchdog tells restarts apart (`wd_restart_reason`): an install, the owner's open (`manual-launch` marker, 5 min) and a reboot are not restarts; a quit through the app (`exit` marker) is `quit`. Restarts before the owner's last open do not count toward a crash loop, and opening Quip lifts a crash-loop stop.
- Not done yet: US-006's phone **Turn on** request, US-007's restart list / Copy for a ticket / Diagnostics bundle files / crash-loop Mac banner, and the phone's "keeps crashing", "disk is full" and "was stopped" wording (the phone does not yet hear those states).

Hardware checks on the owner's Mac (2026-10-31, `f9ee248`):
1. ✓ `launchctl print` → running, pid = Quip's pid; `XPC_SERVICE_NAME` = the agent label.
2. ✓ `kill -9` → back in 4 s. (Not recorded: within the install's 5 min grace.)
3. ✓ `kill -STOP` → `hang … action=killed sample=hang-….txt`, relaunched; restarts.json `hang`. 171 s, because the first two stale checks fell in the install grace.
4–7 and the phone checks: open.
