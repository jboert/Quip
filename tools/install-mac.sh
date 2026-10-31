#!/bin/bash
# Q-90: install a built Quip.app over /Applications/Quip.app without the
# watchdog or launchd taking it for a crash.
#
#   tools/install-mac.sh <path/to/Quip.app>
#
# 1. writes the `installing` marker the watchdog honours for 5 min;
# 2. boots the crash agent out, so launchd does not relaunch the old copy;
# 3. stops the old Quip (it traps SIGTERM, so SIGKILL, by path: `Quip` alone
#    also matches the iOS simulator's app);
# 4. ditto over the old bundle (never rm -rf: TCC grants follow the bundle);
# 5. opens the new Quip, which writes its launch agents for this build and
#    hands the launch to launchd (QuipMac/Services/ReliabilityRuntime.swift).
set -euo pipefail

SRC="${1:?usage: tools/install-mac.sh <path/to/Quip.app>}"
DST=/Applications/Quip.app
EXE="$DST/Contents/MacOS/Quip"
STATE="$HOME/Library/Application Support/Quip"
LABEL=com.quip.QuipMac.crash-recovery

codesign --verify --deep --strict "$SRC"
echo "installing $(/usr/libexec/PlistBuddy -c 'Print :QuipBuildCommit' "$SRC/Contents/Info.plist" 2>/dev/null || echo unstamped)"

mkdir -p "$STATE"
date +%s > "$STATE/installing"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -KILL -f "^$EXE" 2>/dev/null || true
for _ in $(seq 1 50); do pgrep -f "^$EXE" >/dev/null || break; sleep 0.1; done
if pgrep -f "^$EXE" >/dev/null; then
    echo "FAIL: the old Quip is still running"; exit 1
fi

ditto "$SRC" "$DST"
# A Release build over a Debug one leaves these outside the new seal.
[ -e "$SRC/Contents/MacOS/Quip.debug.dylib" ] || rm -f "$DST/Contents/MacOS/Quip.debug.dylib" "$DST/Contents/MacOS/__preview.dylib"
codesign --verify --deep --strict "$DST"

open "$DST"
for _ in $(seq 1 100); do
    pid=$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9]*\)$/\1/p')
    [ -n "$pid" ] && break
    sleep 0.2
done
if [ -n "${pid:-}" ]; then
    echo "OK: Quip pid $pid, started by launchd ($LABEL)"
else
    echo "NOTE: launchd is not running Quip (Keep Quip running off?): $(pgrep -f "^$EXE" || echo 'no Quip running')"
fi
