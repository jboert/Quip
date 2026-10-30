#!/bin/bash
# Q-90 US-002: with the paired Mac's Quip gone (nothing on 127.0.0.1:PORT),
# the phone must classify it as "Quip is down" and show the banner.
# Relaunches Quip on the given simulator only; writes no defaults.
set -uo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:?usage: q90-down.sh <simulator-udid> [port] [screenshot-dir]}"
PORT="${2:-8799}"
SHOTS="${3:-${TMPDIR:-/tmp}}"
BUNDLE=com.fintechadventures.quip

# The app's stdout lands in the (gitignored) repo build dir: the simulator
# could not create the file under $TMPDIR in a sandboxed agent shell.
mkdir -p "$SHOTS" build/qa
OUT="$PWD/build/qa/q90-down.stdout.log"
rm -f "$OUT"

if nc -z -G 1 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    echo "FAIL: something is listening on 127.0.0.1:$PORT; stop it first (the Mac must look down)"
    exit 1
fi

xcrun simctl launch --terminate-running-process --stdout="$OUT" "$UDID" "$BUNDLE" >/dev/null \
    || { echo "FAIL: could not launch Quip on $UDID (not installed, or the simulator refused)"; exit 1; }

found=0
for _ in $(seq 1 450); do
    if grep -q "mac_down kind=quip_down" "$OUT" 2>/dev/null; then found=1; break; fi
    sleep 0.1
done

sleep 1   # let the banner draw
SHOT="$SHOTS/q90-down.png"
xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null 2>&1

if [ "$found" = 1 ]; then
    echo "PASS: $(grep -m1 "mac_down kind=" "$OUT"); screenshot $SHOT"
    exit 0
fi
echo "FAIL: no 'mac_down kind=quip_down' within 45 s; mac_down lines seen:"
grep "mac_down" "$OUT" || echo "  (none)"
echo "screenshot $SHOT"
exit 1
