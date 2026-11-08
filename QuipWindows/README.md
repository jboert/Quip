# Quip for Windows

A small tray app that lets the Quip iPhone app drive a Windows PC the way it
drives a Mac: the phone shows the PC's terminal windows, and you can type into
them, send keys, and arrange, minimize or close them. The iPhone app needs no
change. It pairs with the PC as a second backend next to your Mac.

What works in this build:

- Tray app, pairing by PIN or QR code, Bonjour discovery on the home network.
- The phone's grid of PC windows (PowerShell, cmd and Windows Terminal show as
  terminals; "Show all apps" lists the rest), with the phone's pins and colours.
- Arrange side by side or stacked, minimize and close, from the phone.
- Typing text and keys from the phone into PowerShell, cmd and Windows
  Terminal. Multi-line text is typed into the prompt, and nothing runs until
  you press Return. cmd cannot hold several lines, so multi-line text to cmd
  is refused.
- `Quip.exe --selftest`, which checks this PC and writes a report.

Not yet: reading terminal text back to the phone.

Typing into a window that runs **as administrator** is refused on purpose.
Windows silently drops input from a normal program to an elevated one, so
Quip checks first, types nothing, and the phone shows "is the window running
as administrator?". Run the shell without "Run as administrator" to type
into it from the phone.

## Build (on the Mac)

Once:

```bash
rustup target add x86_64-pc-windows-gnu
brew install mingw-w64
```

Then, from the repo root:

```bash
tools/build-windows.sh
```

It builds `QuipWindows/dist/Quip.exe` (not tracked by git) and checks it. The
exe imports only Windows system DLLs, it is a GUI program (no console window),
and it carries the commit it was built from. At the end it prints the size,
the SHA-256 and the stamp, for example
`stamp: Quip for Windows 0.1.0 (0123456789ab)`. A stamp that ends in
`-dirty` means a file the exe is built from (`QuipWindows/src`, `build.rs`,
`Cargo.toml`, `Cargo.lock`, `.cargo`, `rust-toolchain.toml`) had uncommitted
changes; edits anywhere else in the repo do not count. The script checks the
stamp against `git status` itself and fails when they disagree. Commit first
for a build you hand out.

The script never copies the exe anywhere but `dist/`. Get it to the PC any
way you like: USB stick, cloud drive or a network share.

## Install (on the PC)

1. Copy `Quip.exe` to `%LOCALAPPDATA%\Programs\Quip\` (paste that path into
   File Explorer's address bar; make the `Quip` folder if it is not there).
2. Double-click `Quip.exe`. If SmartScreen says "Windows protected your PC",
   click **More info**, then **Run anyway**. The exe is not signed. Windows
   asks this only for a file marked as downloaded (a cloud drive marks it; a
   USB copy usually does not), and again for each new build so marked.
3. Windows Defender Firewall asks about network access: allow it on
   **Private** networks. If your home network is set to Public, change it to
   Private in Settings > Network & internet > (your network) > Network
   profile type, or the phone cannot connect.
4. Find the Quip icon in the tray (bottom right; it may be under the `^`
   arrow). Click it, choose **Show pairing QR…**, and scan the code with the
   phone. Or wait for the PC to show up in the phone's connection list
   (Bonjour), or add it by address and PIN. The tray menu shows the PIN and
   the PC's addresses.
5. Optional: tray menu > **Start with Windows**.
6. Over Tailscale: Tailscale sets its own network adapter to Private, so the
   firewall rule from step 3 covers it. Bonjour does not cross Tailscale, so
   on the phone add the backend by hand as `ws://<the PC's 100.x address>:8765`
   with the PIN. The tray menu shows the Tailscale address.

Settings (the PIN, the device id, the port, the window choices) live in
`%APPDATA%\Quip\settings.toml`. **New PIN** in the tray menu makes a new PIN
and disconnects every phone; each one must pair again.

## Update

1. Tray menu > **Quit Quip**.
2. Copy the new `Quip.exe` over the old one, at the same path. The firewall
   rule belongs to that path, so it stays, and so do your PIN and pairing.
3. Start it again (SmartScreen may ask again, see Install step 2).

## Check which build is running

- Hover over the tray icon: the tooltip shows `Quip for Windows <version>
  (<commit>)`.
- Or, in PowerShell: `& "$env:LOCALAPPDATA\Programs\Quip\Quip.exe" --version | Out-Host`.

## Selftest

The selftest opens windows of its own (consoles, a Windows Terminal window,
the pairing QR window with a made-up PIN), checks them and closes them again.
It types only into windows it opened, and it changes no setting it does not
put back. Leave the PC alone while it runs (about a minute): if you click into
another window, a check fails rather than type into your window.

- PowerShell: `& "$env:LOCALAPPDATA\Programs\Quip\Quip.exe" --selftest | Out-Host`
- cmd: `start /wait "" "%LOCALAPPDATA%\Programs\Quip\Quip.exe" --selftest`

Each run writes a new `selftest-<time>.txt` in `%LOCALAPPDATA%\Quip\Logs`
(tray menu > **Open logs folder**). Every line should say PASS. Send the newest
file back. It holds no PC name, user name or addresses.

`Quip.exe --help` lists every command. `--input-probe` is internal: the
selftest starts it to check the administrator guard. You never need to run it
yourself.

## Troubleshooting

**The phone cannot connect.** While Quip runs, in cmd or PowerShell:

```
netstat -an | findstr 8765
```

- `TCP    0.0.0.0:8765    0.0.0.0:0    LISTENING` means Quip is listening (IPv4
  only). No such line means Quip is not running, or another program holds the
  port (Quip then says so in a message box).
- Each connected phone adds one `ESTABLISHED` line. If there is none while the
  phone is trying, the firewall or the network profile is blocking it (see
  Install step 3).
- If you dismissed the firewall prompt, Windows may have made a **Block** rule
  for Quip. Open Windows Defender Firewall > Advanced settings > Inbound Rules,
  delete the Block rules for Quip (named "Quip for Windows", or "quip.exe" for
  an older build), and start Quip again to get the prompt back. Do not turn
  the firewall off.

**The logs.** Tray menu > **Open logs folder** opens `%LOCALAPPDATA%\Quip\Logs`:

- `websocket.log`: Quip starting (its first line on each start names the build),
  phones connecting, PIN checks, Bonjour (`mDNS: …`). Read this first when the
  phone cannot connect.
- `injection.log`: every send that failed, one line each, with the reason
  (for example `detail="input blocked (elevated window?)"` for an
  administrator window). Read this when you sent text and nothing happened.
- `latency.log`: how long each send took (counts only, never your text).
- `phone.log`: the phone's own diagnostics, sent over the connection.
- `selftest-<time>.txt`: one per selftest run.

Each log is capped at 10 MB: at the cap it is renamed to `<name>.1` (one old
copy is kept) and a new one starts.

**Bonjour.** If the PC has no home-network address when Quip starts (Wi-Fi not
up yet), Quip checks again every 30 seconds and starts advertising once one
appears (`mDNS: LAN address found, advertising …` in `websocket.log`). The
address list the phone gets when it connects is still the one Quip saw at
start, so restart Quip if the PC's home address changed while it ran.

**Typing into an administrator window does nothing.** This is on purpose, see
the top of this page.

**A second double-click does nothing.** Only one Quip runs per signed-in
Windows session. A second launch exits at once; use the tray icon of the one
that is running.

## Uninstall

1. Tray menu > untick **Start with Windows**.
2. Tray menu > **Quit Quip**.
3. Delete `%LOCALAPPDATA%\Programs\Quip\`.
4. Optional: delete `%APPDATA%\Quip` (the PIN, the device id and the phone's
   saved preferences) and `%LOCALAPPDATA%\Quip` (the logs). Remove the Quip
   rules in Windows Defender Firewall > Advanced settings if you want them gone.

## For developers

- Design spec: `docs/superpowers/specs/2026-11-06-q91-quip-windows-host.md`;
  test plan: `docs/superpowers/specs/2026-11-07-q91-windows-test-plan.md`.
- Gate on the Mac: `printf 'QuipWindows/src/lib.rs\n' | tools/check.sh --files -`
  (fmt, clippy for the Mac and for Windows, `cargo test`). The Win32 UI tests
  and the selftest run in the `Windows` GitHub workflow.
- `Quip --fake-platform` runs the host on the Mac against scripted windows,
  for the simulator checks in `tools/qa/q91-*.sh`.
