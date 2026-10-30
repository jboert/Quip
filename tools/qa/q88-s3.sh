#!/usr/bin/env bash
# q88-s3.sh — Q-88 scenario S3 (US-003 half): with "follow the Mac" off, the
# Mac's frontmost window goes to the top of that Mac's recency stack and the
# phone's selection does not move. (S3's "first in the Recent grid" half needs
# the Recent order, US-004.)
#
#   tools/qa/q88-s3.sh <simulator-udid> [port] [screenshot-dir]
#
# Needs: Quip installed on that simulator and paired with a fake Mac on
# `port` (default 8799; tools/fake-mac/README.md has the pairing link). This
# script starts its own fake Mac on that port, so stop any other one first.
# Use a simulator of your own, never one another session is gating on. It
# turns followFrontmost off for the run and puts the old value back.
#
# Steps: select lantern-web (a quip://window/ link); the fake sends
# `front` for the Safari window. Expect no select_window from the phone, and
# the stored stack (UserDefaults lastSelectedWindow.<backend>) to read
# Safari, then lantern-web.

set -uo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:?usage: q88-s3.sh <simulator-udid> [port] [screenshot-dir]}"
PORT="${2:-8799}"
SHOTS="${3:-${TMPDIR:-/tmp}}"
LANTERN=com.googlecode.iterm2.4117
SAFARI=com.apple.Safari.3318
APP=com.fintechadventures.quip

WORK="$(mktemp -d "${TMPDIR:-/tmp}/q88-s3.XXXXXX")"
FAKE_PID=""
PRIOR_FOLLOW=""
cleanup() {
    if [ -n "$PRIOR_FOLLOW" ]; then xcrun simctl spawn "$UDID" defaults write "$PREFS" followFrontmost -bool "$PRIOR_FOLLOW"; fi
    [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT

xcrun swiftc -O tools/fake-mac/fake-mac.swift -o "$WORK/fake-mac" || exit 1
mkfifo "$WORK/fm.in"
LOG="$WORK/fm.log"
"$WORK/fake-mac" --port "$PORT" --fixture tools/fake-mac/fixture.json --log "$LOG" \
    0<>"$WORK/fm.in" >/dev/null 2>&1 &
FAKE_PID=$!

wait_for() {  # file, regex, seconds
    local i
    for i in $(seq 1 $(($3 * 10))); do
        grep -qE -- "$2" "$1" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

wait_for "$LOG" "listening on ws://127.0.0.1:$PORT" 5 || { echo "FAIL: fake Mac did not start"; exit 1; }
# The app's preferences live in its sandbox container, not in the domain a bare
# `simctl spawn defaults read <bundle-id>` reads; `defaults` takes the plist path.
PREFS="$(xcrun simctl get_app_container "$UDID" "$APP" data)/Library/Preferences/$APP"
stack() {  # the phone's stored recency stack for the fake Mac, one id per line
    xcrun simctl spawn "$UDID" defaults export "$PREFS" - 2>/dev/null \
        | python3 -c 'import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); [print(i) for k,v in d.items() if k.startswith("lastSelectedWindow.") for i in v]'
}
PRIOR_FOLLOW="$(xcrun simctl spawn "$UDID" defaults read "$PREFS" followFrontmost 2>/dev/null || echo 1)"
[ "$PRIOR_FOLLOW" = 0 ] && PRIOR_FOLLOW=false || PRIOR_FOLLOW=true
xcrun simctl terminate "$UDID" "$APP" >/dev/null 2>&1
xcrun simctl spawn "$UDID" defaults write "$PREFS" followFrontmost -bool false
xcrun simctl launch "$UDID" "$APP" >/dev/null || { echo "FAIL: Quip is not installed on $UDID"; exit 1; }
wait_for "$LOG" "AUTHENTICATED" 20 || { echo "FAIL: the phone never authenticated (not paired with port $PORT?)"; exit 1; }
sleep 2

xcrun simctl openurl "$UDID" "quip://window/$LANTERN"
wait_for "$LOG" "frontmost now $LANTERN" 5 || { echo "FAIL: selecting lantern-web never reached the Mac"; exit 1; }
sleep 2   # past the 400 ms echo and the 1 s write

before="$(grep -c 'recv select_window' "$LOG")"
echo "front $SAFARI" >"$WORK/fm.in"
wait_for "$LOG" "cmd front $SAFARI" 5 || { echo "FAIL: the fake Mac did not take 'front'"; exit 1; }
sleep 2   # one coalesced write lands within 1 s
xcrun simctl io "$UDID" screenshot "$SHOTS/q88-s3.png" >/dev/null 2>&1

failures=0
after="$(grep 'recv select_window' "$LOG" | tail -n +$((before + 1)))"
[ -z "$after" ] || { echo "FAIL: follow is off, but the phone selected:"; echo "$after"; failures=1; }
got="$(stack)"
[ "$(printf '%s\n' "$got" | head -1)" = "$SAFARI" ] \
    || { echo "FAIL: want $SAFARI on top of the stack, got:"; echo "$got"; failures=1; }
[ "$(printf '%s\n' "$got" | sed -n 2p)" = "$LANTERN" ] \
    || { echo "FAIL: want $LANTERN second (the phone's own pick), got:"; echo "$got"; failures=1; }

[ "$failures" = 0 ] && echo "S3 passed: $SAFARI on top, selection unchanged; screenshot $SHOTS/q88-s3.png"
exit "$failures"
