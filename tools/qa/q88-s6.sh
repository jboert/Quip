#!/usr/bin/env bash
# q88-s6.sh — Q-88 scenarios S6 and S6b: a relaunch puts the saved place back.
#
#   tools/qa/q88-s6.sh <simulator-udid> [port] [screenshot-dir]
#
# Needs: a DEBUG Quip installed on that simulator and paired with a fake Mac on
# `port` (default 8799; tools/fake-mac/README.md has the pairing link). This
# script starts its own fake Mac on that port, so stop any other one first.
# Use a simulator of your own, never one another session is gating on. It
# turns followFrontmost off for the run (follow beats a saved place) and puts
# the old value back.
#
# Saving the place on background is US-005's job and covered there; this
# seeds the saved place directly so it tests the restore alone:
# lantern-web, terminal expanded, text input open, saved just now.
#
# S6:  relaunch -> `landing reason=restored`, restore steps end
#      window,terminal,input, and one select_window for lantern-web.
# S6b: same place, relaunched with `-QuipNowOffset 1860` (31 min later, DEBUG
#      only) -> the place is stale: restore steps are `window` only, so the
#      panels stay closed.

set -uo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:?usage: q88-s6.sh <simulator-udid> [port] [screenshot-dir]}"
PORT="${2:-8799}"
SHOTS="${3:-${TMPDIR:-/tmp}}"
LANTERN=com.googlecode.iterm2.4117
APP=com.fintechadventures.quip

WORK="$(mktemp -d "${TMPDIR:-/tmp}/q88-s6.XXXXXX")"
FAKE_PID=""
PRIOR_FOLLOW=""
cleanup() {
    if [ -n "$PRIOR_FOLLOW" ]; then xcrun simctl spawn "$UDID" defaults write "$PREFS" followFrontmost -bool "$PRIOR_FOLLOW"; fi
    [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT

wait_for() {  # file, regex, seconds
    local i
    for i in $(seq 1 $(($3 * 10))); do
        grep -qE -- "$2" "$1" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

xcrun swiftc -O tools/fake-mac/fake-mac.swift -o "$WORK/fake-mac" || exit 1
mkfifo "$WORK/fm.in"
LOG="$WORK/fm.log"
"$WORK/fake-mac" --port "$PORT" --fixture tools/fake-mac/fixture.json --log "$LOG" \
    0<>"$WORK/fm.in" >/dev/null 2>&1 &
FAKE_PID=$!
wait_for "$LOG" "listening on ws://127.0.0.1:$PORT" 5 || { echo "FAIL: fake Mac did not start"; exit 1; }

# The app's preferences live in its sandbox container; `defaults` takes the plist path.
PREFS="$(xcrun simctl get_app_container "$UDID" "$APP" data)/Library/Preferences/$APP" \
    || { echo "FAIL: Quip is not installed on $UDID"; exit 1; }
PRIOR_FOLLOW="$(xcrun simctl spawn "$UDID" defaults read "$PREFS" followFrontmost 2>/dev/null || echo 1)"
[ "$PRIOR_FOLLOW" = 0 ] && PRIOR_FOLLOW=false || PRIOR_FOLLOW=true

# The fake Mac's backend id: the key of the recency stack the phone keeps for it.
BACKEND="$(xcrun simctl spawn "$UDID" defaults export "$PREFS" - 2>/dev/null | python3 -c '
import plistlib,sys
keys=[k for k in plistlib.loads(sys.stdin.buffer.read()) if k.startswith("lastSelectedWindow.")]
print(keys[0].split(".",1)[1] if keys else "")')"
[ -n "$BACKEND" ] || { echo "FAIL: no recency stack yet -- pair with the fake Mac and pick a window once"; exit 1; }

run() {  # name, extra launch args...
    local name="$1"; shift
    xcrun simctl terminate "$UDID" "$APP" >/dev/null 2>&1
    xcrun simctl spawn "$UDID" defaults write "$PREFS" followFrontmost -bool false
    # JSONEncoder's default Date is seconds since 2001-01-01.
    local hex
    hex="$(python3 -c '
import json,time,sys
p={"selectedWindowId":sys.argv[1],"textInputOpen":True,"terminalExpanded":True,
   "scrollAnchorByWindow":{},"savedAt":time.time()-978307200}
print(json.dumps(p).encode().hex())' "$LANTERN")"
    xcrun simctl spawn "$UDID" defaults write "$PREFS" "phonePlace.v1.$BACKEND" -data "$hex"
    local start; start="$(wc -l <"$LOG")"
    xcrun simctl launch "$UDID" "$APP" "$@" >/dev/null || { echo "FAIL: launch"; exit 1; }
    for _ in $(seq 1 200); do tail -n +"$((start + 1))" "$LOG" >"$LOG.$name"; grep -q "place restore" "$LOG.$name" && break; sleep 0.1; done
    sleep 1.5
    tail -n +"$((start + 1))" "$LOG" >"$LOG.$name"
    xcrun simctl io "$UDID" screenshot "$SHOTS/q88-$name.png" >/dev/null 2>&1
}

failures=0
check() {  # name, regex, message
    grep -qE -- "$2" "$LOG.$1" || { echo "FAIL ($1): $3"; failures=1; }
}

run s6
check s6 "landing reason=restored" "no 'landing reason=restored'"
check s6 "place restore saved=true fresh=true steps=.*window,terminal,input" "panels not restored"
[ "$(grep -c "recv select_window window=$LANTERN" "$LOG.s6")" = 1 ] \
    || { echo "FAIL (s6): want one select_window for lantern-web"; failures=1; }

run s6b -QuipNowOffset 1860
check s6b "place restore saved=true fresh=false steps=window( |$)" "a stale place restored more than the window"

[ "$failures" = 0 ] && echo "S6 + S6b passed; screenshots $SHOTS/q88-s6.png, $SHOTS/q88-s6b.png"
exit "$failures"
