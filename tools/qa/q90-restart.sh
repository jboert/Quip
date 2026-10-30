#!/usr/bin/env bash
# q90-restart.sh — Q-90 US-004: after the Mac restarts Quip, the phone says
# why, once. A fake Mac reports a crash restart; the phone must log
# `mac_restarted reason=crash` (it reaches fm.log as a phone_log line).
#
#   tools/qa/q90-restart.sh <simulator-udid>
#
# Needs: Quip installed on that simulator and paired with a fake Mac on 8799
# (PIN 11112222; tools/fake-mac/README.md has the pairing link). This script
# starts its own fake Mac there, so stop any other one first. Relaunches Quip
# on the given simulator only; writes no defaults.

set -uo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:?usage: q90-restart.sh <simulator-udid>}"
PORT=8799
BUNDLE=com.fintechadventures.quip

WORK="$(mktemp -d "${TMPDIR:-/tmp}/q90-restart.XXXXXX")"
FAKE_PID=""
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

wait_for() {  # file, regex, seconds
    local i
    for i in $(seq 1 $(($3 * 10))); do
        grep -qE -- "$2" "$1" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

if nc -z -G 1 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    echo "FAIL: something is already listening on 127.0.0.1:$PORT; stop it first"
    exit 1
fi

xcrun swiftc -O tools/fake-mac/fake-mac.swift -o "$WORK/fake-mac" || { echo "FAIL: fake Mac did not compile"; exit 1; }
mkfifo "$WORK/fm.in"
LOG="$WORK/fm.log"
"$WORK/fake-mac" --port "$PORT" --pin 11112222 --fixture tools/fake-mac/fixture.json --log "$LOG" \
    0<>"$WORK/fm.in" >/dev/null 2>&1 &
FAKE_PID=$!

wait_for "$LOG" "listening on ws://127.0.0.1:$PORT" 5 || { echo "FAIL: fake Mac did not start"; exit 1; }
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" >/dev/null \
    || { echo "FAIL: could not launch Quip on $UDID (not installed, or the simulator refused)"; exit 1; }
wait_for "$LOG" "AUTHENTICATED" 20 || { echo "FAIL: the phone never authenticated (not paired with port $PORT?)"; exit 1; }

echo "reliability on crash" >"$WORK/fm.in"
if wait_for "$LOG" "mac_restarted reason=crash" 20; then
    echo "PASS: $(grep -m1 -oE 'recv phone_log.*mac_restarted reason=crash' "$LOG" | cut -c1-200)"
    exit 0
fi
echo "FAIL: no 'mac_restarted reason=crash' from the phone within 20 s; reliability lines seen:"
grep -E "reliability|mac_restarted" "$LOG" || echo "  (none)"
exit 1
