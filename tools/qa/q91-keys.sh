#!/usr/bin/env bash
# q91-keys.sh — Q-91 spec 10.6: the phone's key buttons (Return, Esc,
# Ctrl+C, Up, Down) arrive at the Windows host as the right quick_action and
# press the right key.
#
#   tools/qa/q91-keys.sh <simulator-udid> [port] [screenshot-dir]
#
# Needs: Quip installed on that simulator, idb, cargo. Starts its own fake
# Windows host on `port` (default 8797) and pairs by the PIN link.
#
# Sets the phone's quick-button row to Esc, Ctrl+C, Up, Down for the run and
# puts the old row back on exit (quickSlotsJSON, written while the app is
# quit). Return is the main row's Return button. Selects Windows PowerShell
# (handle 4117) through a quip://window/ link, taps each button and expects,
# per tap, `fake: key handle=4117 chord=<key>` and a latency.log
# `quick_action action=<action> ... success=1`.
#
# Evidence: <screenshot-dir>/s5-q91-keys.png.

UDID="${1:?usage: q91-keys.sh <simulator-udid> [port] [screenshot-dir]}"
PORT="${2:-8797}"
SHOTS="$(mkdir -p "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && cd "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && pwd)"
NAME=q91-keys
. "$(dirname "$0")/q91-lib.sh"

q91_start_fake

PREFS="$(q91_prefs)" || { echo "FAIL: Quip is not installed on $UDID"; exit 1; }
xcrun simctl terminate "$UDID" "$APP" >/dev/null 2>&1
xcrun simctl spawn "$UDID" defaults read "$PREFS" quickSlotsJSON >"$WORK/slots.orig" 2>/dev/null
restore_slots() {
    xcrun simctl terminate "$UDID" "$APP" >/dev/null 2>&1
    if [ -s "$WORK/slots.orig" ]; then
        xcrun simctl spawn "$UDID" defaults write "$PREFS" quickSlotsJSON -string "$(cat "$WORK/slots.orig")"
    else
        xcrun simctl spawn "$UDID" defaults delete "$PREFS" quickSlotsJSON >/dev/null 2>&1
    fi
}
EXTRA_CLEANUP=restore_slots
xcrun simctl spawn "$UDID" defaults write "$PREFS" quickSlotsJSON -string \
    '[{"kind":"builtin","button":"esc"},{"kind":"builtin","button":"ctrlC"},{"kind":"builtin","button":"arrowUp"},{"kind":"builtin","button":"arrowDown"}]'

q91_pair
xcrun simctl openurl "$UDID" "quip://window/$W_POWERSHELL"
wait_for "$OUT" "focus handle=4117 " 5 || { echo "FAIL: selecting Windows PowerShell never reached the host"; exit 1; }
sleep 1.5
shot s5-q91-keys
# Without the keyboard up the main row sits at y 836 and the quick row at 886.
ocr "$SHOTS/s5-q91-keys.png" | grep -q 'Type a prompt' || { echo "FAIL: expected the compose bar with the keyboard down"; exit 1; }

LAT="$LOGS/latency.log"
press() {  # label x y chord action
    local mark lmark
    mark=$(lines); lmark=$([ -f "$LAT" ] && wc -l <"$LAT" | tr -d ' ' || echo 0)
    idb ui tap --udid "$UDID" "$2" "$3" >/dev/null
    wait_for "$OUT" "key handle=4117 chord=${4//+/\\+}\$" 4
    sleep 0.5
    check "$1 presses $4" "key handle=4117 chord=$4" "$(since "$mark" | grep -o 'key handle=.*' | paste -sd'|' -)"
    expect "$1 is quick_action $5 in latency.log" \
        grep -qE "quick_action .*action=$5 .*success=1 inputs=1" <(tail -n +$((lmark + 1)) "$LAT")
}
press "Return button" 291 836 return press_return
press "Esc button" 26 886 escape press_escape
press "Ctrl+C button" 53 886 ctrl+c press_ctrl_c
press "Up button" 80 886 up press_up
press "Down button" 107 886 down press_down

finish "$SHOTS/s5-q91-keys.png"
