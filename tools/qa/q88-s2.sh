#!/usr/bin/env bash
# q88-s2.sh — Q-88 scenario S2: when the selected window closes, the phone
# lands on the window the user was in before it, not on the Mac's first.
#
#   tools/qa/q88-s2.sh <simulator-udid> [port] [screenshot-dir]
#
# Needs: Quip installed on that simulator and paired with a fake Mac on
# `port` (default 8799; tools/fake-mac/README.md has the pairing link). This
# script starts its own fake Mac on that port, so stop any other one first.
# Use a simulator of your own, never one another session is gating on.
#
# Steps: select lantern-web, then dotfiles (both through quip://window/ links,
# a real selection path); the fake closes dotfiles. Expect exactly one
# select_window for lantern-web and `landing reason=recent` in the phone log.
# orchard-api is the fixture's first window, so landing there would mean the
# recency stack was ignored.

set -uo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:?usage: q88-s2.sh <simulator-udid> [port] [screenshot-dir]}"
PORT="${2:-8799}"
SHOTS="${3:-${TMPDIR:-/tmp}}"
LANTERN=com.googlecode.iterm2.4117
DOTFILES=com.apple.Terminal.2290

WORK="$(mktemp -d "${TMPDIR:-/tmp}/q88-s2.XXXXXX")"
FAKE_PID=""
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$WORK"; }
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
xcrun simctl terminate "$UDID" com.fintechadventures.quip >/dev/null 2>&1
xcrun simctl launch "$UDID" com.fintechadventures.quip >/dev/null || { echo "FAIL: Quip is not installed on $UDID"; exit 1; }
wait_for "$LOG" "AUTHENTICATED" 20 || { echo "FAIL: the phone never authenticated (not paired with port $PORT?)"; exit 1; }
sleep 2

xcrun simctl openurl "$UDID" "quip://window/$LANTERN"
wait_for "$LOG" "frontmost now $LANTERN" 5 || { echo "FAIL: selecting lantern-web never reached the Mac"; exit 1; }
xcrun simctl openurl "$UDID" "quip://window/$DOTFILES"
wait_for "$LOG" "frontmost now $DOTFILES" 5 || { echo "FAIL: selecting dotfiles never reached the Mac"; exit 1; }

before="$(grep -c 'recv select_window' "$LOG")"
echo "close dotfiles" >"$WORK/fm.in"
wait_for "$LOG" "landing reason=" 5
sleep 1
xcrun simctl io "$UDID" screenshot "$SHOTS/q88-s2.png" >/dev/null 2>&1

after_selects="$(grep 'recv select_window' "$LOG" | tail -n +$((before + 1)))"
failures=0
[ "$(printf '%s\n' "$after_selects" | grep -c .)" = "1" ] \
    || { echo "FAIL: want exactly one select_window after the close, got:"; echo "$after_selects"; failures=1; }
printf '%s\n' "$after_selects" | grep -q "window=$LANTERN" \
    || { echo "FAIL: the phone did not land on lantern-web"; failures=1; }
grep -q "landing reason=recent" "$LOG" \
    || { echo "FAIL: phone.log has no 'landing reason=recent'"; failures=1; }

[ "$failures" = 0 ] && echo "S2 passed: landed on lantern-web (reason=recent); screenshot $SHOTS/q88-s2.png"
exit "$failures"
