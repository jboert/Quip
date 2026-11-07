#!/usr/bin/env bash
# q91-two-backends.sh — Q-91 spec 10.6: the phone paired with a fake Mac and
# the fake Windows host at once; both stay authenticated, and switching
# between them shows each one's own grid.
#
#   tools/qa/q91-two-backends.sh <simulator-udid> [port] [screenshot-dir]
#
# Needs: Quip installed on that simulator, idb, cargo. Starts its own fake
# Windows host on `port` (default 8797) and its own fake Mac
# (tools/fake-mac) on QUIP_FAKE_MAC_PORT (default 8799, the port the QA
# simulator's fake-Mac row uses), then pairs both by their PIN links.
# Neither port may be in use already; stop any other fake first.
#
# Checks: each fake authenticated the phone and holds one live socket from it;
# the Backends sheet switches to the Mac (its cards: orchard-api,
# lantern-web, dotfiles; no Windows card) and back to Windows (its cards;
# no Mac card); neither fake saw a new authentication while switching, so
# the switch kept both connections.
#
# Evidence: <screenshot-dir>/s5-q91-two-backends.png (Windows grid after the
# round trip) and s5-q91-two-backends-mac.png (the Mac grid).

UDID="${1:?usage: q91-two-backends.sh <simulator-udid> [port] [screenshot-dir]}"
PORT="${2:-8797}"
MAC_PORT="${QUIP_FAKE_MAC_PORT:-8799}"
SHOTS="$(mkdir -p "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && cd "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && pwd)"
NAME=q91-two-backends
. "$(dirname "$0")/q91-lib.sh"

[ "$MAC_PORT" = 8765 ] || [ "$MAC_PORT" = "$PORT" ] && { echo "FAIL: the fake Mac needs its own port (not 8765, not $PORT)"; exit 2; }
lsof -nP -iTCP:"$MAC_PORT" -sTCP:LISTEN >/dev/null 2>&1 && { echo "FAIL: port $MAC_PORT is in use; stop the other fake first"; exit 1; }

MAC_PID=""
stop_mac() { [ -n "$MAC_PID" ] && kill "$MAC_PID" 2>/dev/null; }
EXTRA_CLEANUP=stop_mac
xcrun swiftc -O tools/fake-mac/fake-mac.swift -o "$WORK/fake-mac" || exit 1
mkfifo "$WORK/fm.in"
FM_LOG="$WORK/fm.log"
"$WORK/fake-mac" --port "$MAC_PORT" --pin "$PIN" --fixture tools/fake-mac/fixture.json --log "$FM_LOG" \
    0<>"$WORK/fm.in" >/dev/null 2>&1 &
MAC_PID=$!
wait_for "$FM_LOG" "listening on ws://127.0.0.1:$MAC_PORT" 10 || { echo "FAIL: fake Mac did not start"; exit 1; }

q91_start_fake

# Pair the Mac first, then Windows: the last pairing is the one shown.
xcrun simctl terminate "$UDID" "$APP" >/dev/null 2>&1
xcrun simctl launch "$UDID" "$APP" >/dev/null || { echo "FAIL: Quip is not installed on $UDID"; exit 1; }
sleep 2
xcrun simctl openurl "$UDID" "$(pair_link "$MAC_PORT")"; sleep 1; tap_open_prompt
wait_for "$FM_LOG" "AUTHENTICATED" 20 || { echo "FAIL: the phone never authenticated with the fake Mac"; exit 1; }
xcrun simctl openurl "$UDID" "$(pair_link "$PORT")"; sleep 1; tap_open_prompt
wait_for "$LOGS/websocket.log" "auth ok from 127.0.0.1" 20 || { echo "FAIL: the phone never authenticated with the fake Windows host"; exit 1; }
sleep 3

sockets() {  # port -> live sockets the fake on that port holds
    lsof -nP -a -p "$1" -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep -c "127.0.0.1:$2->"
}
auths() { echo "$(grep -c AUTHENTICATED "$FM_LOG") $(grep -c 'auth ok' "$LOGS/websocket.log")"; }
check "fake Mac holds one socket from the phone" 1 "$(sockets "$MAC_PID" "$MAC_PORT")"
check "fake Windows holds one socket from the phone" 1 "$(sockets "$FAKE_PID" "$PORT")"
auth_before="$(auths)"

tap_text() {  # regex [max-y]: tap the first OCR line matching it
    local xy
    xcrun simctl io "$UDID" screenshot "$WORK/tap.png" >/dev/null 2>&1
    xy="$(ocr "$WORK/tap.png" | awk -v re="$1" -v maxy="${2:-9999}" '$0 ~ re && $2 <= maxy {print $1, $2; exit}')"
    [ -n "$xy" ] || { echo "FAIL: '$1' is not on screen"; return 1; }
    idb ui tap --udid "$UDID" $xy >/dev/null
}
switch_to() {  # port
    tap_text "paired" 120 || return 1
    sleep 1.5
    tap_text "127\\.0\\.0\\.1:$1" || return 1
    # Picking a row closes the sheet; Done is only there if it did not.
    sleep 1.5
    xcrun simctl io "$UDID" screenshot "$WORK/tap.png" >/dev/null 2>&1
    ocr "$WORK/tap.png" | grep -qE '^[0-9]+ [0-9]+ Done$' && tap_text '^[0-9]+ [0-9]+ Done$' 200
    sleep 1.5
}

WIN_CARDS="pebble-docs|Command Prompt"
MAC_CARDS="lantern-web|dotfiles"
expect "Windows grid shown after pairing" on_screen "pebble-docs" 6

switch_to "$MAC_PORT" || failures=$((failures + 1))
expect "switch to the Mac shows lantern-web" on_screen "lantern-web" 6
cp "$WORK/poll.png" "$SHOTS/s5-q91-two-backends-mac.png"
ocr "$SHOTS/s5-q91-two-backends-mac.png" >"$WORK/mac.txt"
check "the Mac grid has its own cards" yes "$(grep -q dotfiles "$WORK/mac.txt" && grep -q orchard-api "$WORK/mac.txt" && echo yes || echo no)"
check "the Mac grid has no Windows card" "" "$(grep -E "$WIN_CARDS" "$WORK/mac.txt")"

switch_to "$PORT" || failures=$((failures + 1))
expect "switch back to Windows shows pebble-docs" on_screen "pebble-docs" 6
cp "$WORK/poll.png" "$SHOTS/s5-q91-two-backends.png"
ocr "$SHOTS/s5-q91-two-backends.png" >"$WORK/win.txt"
check "the Windows grid has its four terminals" yes "$(grep -q 'Command Prompt' "$WORK/win.txt" && grep -q 'Windows PowerShell' "$WORK/win.txt" && grep -q 'pwsh in orchar' "$WORK/win.txt" && echo yes || echo no)"
check "the Windows grid has no Mac card" "" "$(grep -E "$MAC_CARDS" "$WORK/win.txt")"

check "no re-authentication while switching (Mac, Windows)" "$auth_before" "$(auths)"
check "fake Mac still holds its socket" 1 "$(sockets "$MAC_PID" "$MAC_PORT")"
check "fake Windows still holds its socket" 1 "$(sockets "$FAKE_PID" "$PORT")"

finish "$SHOTS/s5-q91-two-backends.png $SHOTS/s5-q91-two-backends-mac.png"
