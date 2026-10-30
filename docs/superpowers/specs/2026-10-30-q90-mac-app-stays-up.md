# Spec: The Mac app stays up, and the phone can get you back in when it doesn't — Q-90

Status: **spec only, no code**. Written 2026-10-30.
Platform: QuipMac (stories 1–4, one Mac rebuild for the lot) and QuipiOS (stories 5–6, phone-only). Remote access is Tailscale only (no tunnel, owner 2026-10-28).

## 1. Why

Owner, 2026-10-30: "if I'm mobile and remote and all of a sudden the desktop app is turned off or crashes, which does happen frequently … how do I ensure this will still work? Is there an easy way to restart the app on the remote device?"

When Quip on the Mac is gone, the phone has nothing to talk to: no windows, no Remote in from a window, no restart button. The fix has three layers, cheapest first:

1. **The Mac restarts Quip by itself** after a crash or a hang, so most of the time nothing reaches the phone.
2. **The phone says what is wrong**: Mac offline, or Mac up and Quip down. These need different fixes.
3. **One tap in from the phone** (Screen Sharing over Tailscale, which runs without Quip) for whatever is left.

## 2. What the code does today (checked 2026-10-30 at `28883ae`)

| Area | Today | Where |
|---|---|---|
| Crash restart | Opt-in LaunchAgent `com.quip.QuipMac.crash-recovery`: `KeepAlive {Crashed: true, SuccessfulExit: false}`, `RunAtLoad`, `ThrottleInterval 30`, execs `Contents/MacOS/Quip` | `QuipMac/Services/CrashRecoveryAgent.swift`, toggle in Settings → General → Reliability |
| Two launchers | The login item (LaunchServices) and the agent (raw exec) both start Quip at login. The loser of the `flock` race **exits 0** so launchd does not loop | `QuipMac/Services/SingleInstanceGuard.swift`, `QuipMacApp.swift` ~397 |
| **The gap** | On the owner's Mac now: agent installed, `state = not running, runs = 1, last exit code = 0`, while Quip pid 55460 runs from a manual open. The agent's copy lost the race, exited 0, and launchd will never start it again. **The running Quip is unsupervised: a crash now is not restarted.** The same thing happens after every install, because the recipe relaunches with `open` | `launchctl print gui/501/com.quip.QuipMac.crash-recovery` |
| Hangs | Not covered. Quip's "crashes" have been hangs (a blocking call on the main actor); `KeepAlive.Crashed` never fires for a hang | memory: quip-hangs-not-crashes; `/Library/Logs/DiagnosticReports/Quip_*.hang` |
| Screen Sharing | On (`com.apple.screensharing` active, ARD all users). Works with Quip dead | macOS |
| Mac sleep | `sleep 0` (kept awake by Amphetamine/caffeinate); `womp 1` | `pmset -g` |
| Phone when Quip is gone | Shows "Unreachable" on the backend row and reconnects on its own backoff; no hint of what is down; Remote in only from the Backends long-press | `QuipiOS/Views/BackendPickerSheet.swift`, US-011 |

## 3. Stories

Order is the build order. Stories 1–4 change QuipMac: build them together and rebuild the Mac once (each rebuild costs the Accessibility and Screen Recording grants; do it while the owner is at the Mac).

### US-001: launchd always owns the running Quip
- [ ] When the agent is installed and Quip was **not** started by it (`XPC_SERVICE_NAME` is not the agent label), Quip runs `launchctl kickstart gui/<uid>/<label>` and exits 0 **before** claiming the instance lock. The agent's copy starts, wins the lock, and is supervised.
- [ ] Guard against a loop: if the kickstart fails (agent not loaded, launchctl error), log it and keep running as the unsupervised copy (fail open, same as the lock).
- [ ] The login item is removed when the agent is turned on (the agent's `RunAtLoad` covers login), and put back when it is turned off.
- [ ] `docs/` install recipe and `reference_quip_install_recipe` memory: relaunch with `launchctl kickstart -k gui/$(id -u)/com.quip.QuipMac.crash-recovery`, not `open`.
- [ ] `KeepAlive` = `true` (§6.1). Menu-bar Quit is replaced by **Stop Quip…** (confirm → `launchctl bootout gui/<uid>/<label>`, then exit). Opening Quip again re-bootstraps the agent.
- [ ] Settings → Reliability shows the true state: "Watching Quip (pid N)" / "Installed, but not watching — Fix" (Fix = kickstart).
- [ ] Pure `LaunchOwnership.decide(agentInstalled:launchedByAgent:) -> .run | .handOff` + tests.
- [ ] Check after install: `launchctl print …` shows `state = running` with Quip's pid.

### US-002: A hung Quip is restarted
- [ ] Quip writes a heartbeat (Unix time) to `~/Library/Application Support/Quip/heartbeat` every 10 s **from the main actor**, so a blocked main thread stops it.
- [ ] A second LaunchAgent `com.quip.QuipMac.watchdog` (`StartInterval 30`, runs `/bin/sh` on a script inside the app bundle: no TCC, no new binary) checks: Quip's pid is alive and the heartbeat is older than 60 s (§6.2) → `sample <pid> 3` to `~/Library/Logs/Quip/hang-<time>.txt` → `kill -9`. The `-9` counts as a crash, so US-001's agent restarts Quip.
- [ ] Never kill during the first 120 s after Quip starts (launch can be slow), and never more than 3 times in 30 min (then log and leave it up, so a hang loop is visible, not hidden).
- [ ] **Crash-loop stop** (owner: "don't let it keep crashing"). The watchdog also counts the crash agent's restarts (`launchctl print` `runs` plus its own kills, kept in `~/Library/Application Support/Quip/restarts.json`). **3 restarts within 10 min → `launchctl bootout` the crash agent and leave Quip down**, write `crash_loop restarts=3 window=10m action=stopped` to `watchdog.log`, and drop a `stoppedForCrashLoop` marker. It lives in the watchdog, not in Quip, so it still works when Quip dies before its own code runs. Opening Quip by hand clears the marker and re-bootstraps the agent.
- [ ] Installed and removed with the same Reliability toggle.
- [ ] `~/Library/Logs/Quip/watchdog.log`: one line per check that acts (`hang pid=N heartbeat_age=Ns action=killed sample=hang-….txt`), plus a throttled `ok` line every 30 min.
- [ ] The decision (`age`, `uptime`, `recentKills`) is a pure function in the script, tested by `tools/check.sh`'s harness with fixed inputs.

### US-003: The Mac tells the phone it restarted
- [ ] On launch Quip reads a `cleanShutdown` marker (written on normal quit, cleared at start). Missing → the last run crashed or was killed.
- [ ] After auth, the Mac sends `mac_restarted {reason: crash|hang|crash_loop|unknown, at}` once per restart (hang = a fresh `hang-*.txt` from the watchdog). New message type in `Shared/MessageProtocol.swift`; an older phone ignores it.
- [ ] The phone shows an `ActionToast`: "Quip on your Mac restarted after a crash (2:04 pm)" with **Details**, which opens the Connection diagnostics. `phone.log`: `mac_restarted reason=…`.

### US-004: Every restart is a bug to fix, not a fix
Restarting is the net; a healthy Quip is the goal (owner: "healthy quip is good").
- [ ] Settings → Reliability lists the last 5 restarts: time, reason, and for each the **top three Quip frames** (from the `.ips` crash report, or the `sample` the watchdog took for a hang). "It crashes frequently" becomes a count and a place in the code.
- [ ] **Copy for a ticket** on each row: the frames, build commit, uptime and reason as plain text, no paths under the home folder, no window titles.
- [ ] The Diagnostics bundle (phone → Request Mac bundle) includes `watchdog.log` and the last 3 `hang-*.txt`.
- [ ] After a crash-loop stop, the first launch by hand shows a one-time banner on the Mac ("Quip was stopped after 3 crashes in 10 minutes") with the same frames, and the phone gets `mac_restarted reason=crash_loop`.

### US-005 (phone): Say what is down
- [ ] When the active Mac has been unreachable for 15 s, the phone probes the Mac's Tailscale host on TCP 5900 (Screen Sharing) with a 3 s timeout.
  - 5900 answers, 8765 does not → **"Quip isn't running on your Mac"**.
  - Neither answers → **"Your Mac is offline or Tailscale is off"**, with "Check Tailscale on this phone" (the 2026-10-30 outage was the phone's Tailscale asleep).
- [ ] The probe socket is closed on every path (cf. the probe-socket leak, 1dbd64b). One probe per 60 s at most.
- [ ] `phone.log`: `mac_down kind=quip_down|offline probe_ms=N`; no host.
- [ ] Pure `MacDownClassifier.classify(quipPort:screenSharing:) -> .quipDown | .offline | .unknown` + tests.

### US-006 (phone): One tap in from the "down" banner
- [ ] The banner from US-005 carries **Remote in** (US-010/011 setting, no window step) so the owner lands in Screen Sharing and can open Quip there.
- [ ] Hidden when the Remote-in preset needs a host and none is set; then the button reads **Set up Remote in**.
- [ ] Sim scenario: fake Mac `dead` → banner within 20 s; with a local listener on 5900 → "Quip isn't running"; tap → `remote_in … result=no_app` on the sim.

## 4. Non-goals (v1)

- **Restart from the phone without Screen Sharing** (Tailscale SSH + `launchctl kickstart`). It works and would be one tap, but needs Tailscale SSH turned on and an SSH identity on the phone. Revisit if the US-001/US-002 restarts are not enough.
- Waking a sleeping Mac. The owner's Mac does not sleep (`sleep 0`); Wake-on-LAN does not cross Tailscale.
- A Quip helper daemon that outlives the app. launchd is the supervisor.

## 5. Tests and checks

- Unit: `LaunchOwnership`, the watchdog decision (age 59 s → ok, 61 s → kill, uptime 100 s → wait, 3 kills in 30 min → leave up), clean-shutdown marker read/write, `MacDownClassifier`.
- Mutation check per pure type, results in the commit message.
- Mac hardware check (owner present, after the one rebuild):
  1. `launchctl print gui/501/com.quip.QuipMac.crash-recovery` → `running`, Quip's pid.
  2. `kill -9 <pid>` → back within 30 s; the phone toasts "restarted after a crash".
  3. Simulate a hang: `kill -STOP <pid>` → the watchdog samples and kills within 90 s; the agent restarts it; the phone toasts "after a hang".
  4. `osascript -e 'quit app "Quip"'` → back within 30 s (any exit comes back, §6.1).
  5. Menu bar → Stop Quip… → confirm → stays stopped; `launchctl print` shows the agent gone. Open Quip → the agent is back and running.
- Phone hardware check (remote, on cellular): quit Quip on the Mac → the phone shows "Quip isn't running on your Mac" → Remote in → Screen Sharing → open Quip → the phone reconnects.

## 6. Decisions (owner, 2026-10-30: "what's best")

1. **Any exit comes back.** From the phone an accidental quit and a crash look the same: you are locked out. The agent's `KeepAlive` becomes `true` (restart after any exit). The menu-bar **Quit** becomes **Stop Quip…**: it asks to confirm, then runs `launchctl bootout` on the agent so Quip stays stopped until the next login or until it is opened again. The single-instance loser now hands off (US-001) instead of exiting, so `SuccessfulExit` no longer carries the loop guard; `ThrottleInterval 30` still does.
2. **Hang threshold 60 s.** The watchdog checks every 30 s and launchd waits up to 30 s to relaunch, so the worst case is about 2 min down (90 s would be about 2.5 min). A healthy Quip never blocks its main thread for 60 s.
3. **Settings, all optional, all on by default** (owner: "settings should be optional too if better"). Settings → General → Reliability:
   - **Restart Quip if it crashes or freezes**: the master switch; installs or removes both agents. Today's toggle defaults to off. It becomes on by default: a fresh install installs the agents on first launch, and an existing install turns it on once (migration flag), because the owner's Mac shows the off state costs exactly the case this spec is for.
   - **Also restart after Quit** (indented, needs the master): on = `KeepAlive true` and the **Stop Quip…** menu item (§6.1); off = today's `KeepAlive {Crashed: true, SuccessfulExit: false}` and a plain Quit.
   - **Restart a frozen Quip** (indented, needs the master): installs or removes the watchdog agent (US-002).
   - The 60 s threshold is **not** a setting. A wrong value either kills a healthy Quip or leaves the owner locked out, and nobody can judge it from a settings screen. It is one constant, tuned from `watchdog.log`.
   - The three values ride the Mac's own UserDefaults (the Mac has no settings backup). Pure `ReliabilitySettings.agents(master:afterQuit:frozen:) -> (keepAlive:, watchdog:)` + tests.
