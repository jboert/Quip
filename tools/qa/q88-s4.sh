#!/usr/bin/env bash
# q88-s4.sh — Q-88 scenario S4 (US-004): Recent is the default grid order; a drag switches to
# Manual with a "Use Recent" toast, and the toast's button brings Recent back.
# Also checks that recency writes are not settings edits (the backup stamp
# stays put when the Mac changes focus).
#
# Needs: Quip installed on <udid> and paired with ws://127.0.0.1:<port>
# (pairing link: quip://pair?url=<base64 of the ws URL, no padding>&pin=11112222),
# and idb. Resets only the grid-order keys and the recency stack.
set -uo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:?usage: q88-s4.sh <simulator-udid> [port] [screenshot-dir]}"
PORT="${2:-8799}"
SHOTS="${3:-${TMPDIR:-/tmp}}"
PINNED=com.googlecode.iterm2.4101
LANTERN=com.googlecode.iterm2.4117
DOTFILES=com.apple.Terminal.2290
SAFARI=com.apple.Safari.3318
APP=com.fintechadventures.quip

WORK="$(mktemp -d "${TMPDIR:-/tmp}/q88-s4.XXXXXX")"
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

DATA="$(xcrun simctl get_app_container "$UDID" "$APP" data)" || { echo "FAIL: Quip is not installed on $UDID"; exit 1; }
PREFS="$DATA/Library/Preferences/$APP"
META="$DATA/Library/Preferences/$APP.prefs-meta"
pref() { xcrun simctl spawn "$UDID" defaults read "$PREFS" "$1" 2>/dev/null; }
stamp() { xcrun simctl spawn "$UDID" defaults read "$META" prefs.localModifiedAt 2>/dev/null || echo none; }
# Window tiles top-to-bottom, left-to-right, as "id x y" (points, centers).
tiles() {
    idb ui describe-all --udid "$UDID" --json 2>/dev/null | python3 -c '
import json, sys
els = json.load(sys.stdin)
rows = []
for e in els:
    uid = e.get("AXUniqueId") or ""
    if uid.startswith("window-tile-"):
        f = e["frame"]
        # Row by center, in 20 pt bands: the selected tile is drawn a point
        # or two higher than its neighbours, so raw y would sort it first.
        cy = f["y"] + f["height"] / 2
        rows.append((round(cy / 20), f["x"], uid[len("window-tile-"):], f["x"] + f["width"] / 2, cy))
for y, x, i, cx, cy in sorted(rows):
    print(i, round(cx), round(cy))'
}
order() { tiles | awk '{print $1}' | paste -sd' ' -; }
# The Recent order is taken when the user comes back to the app, never while
# they tap around (a card must not slide away under the next tap).
come_back() {
    idb ui button --udid "$UDID" HOME >/dev/null 2>&1
    sleep 1.5
    xcrun simctl launch "$UDID" "$APP" >/dev/null
    sleep 2
}
center() { tiles | awk -v id="$1" '$1 == id {print $2, $3}'; }
button() {  # the toast's action: right end of the element whose label names $1
    # The toast is one VoiceOver element (text + button), so its button is
    # found by position: the trailing 40 pt of the capsule.
    idb ui describe-all --udid "$UDID" --json 2>/dev/null | python3 -c '
import json, sys
for e in json.load(sys.stdin):
    if sys.argv[1] in (e.get("AXLabel") or ""):
        f = e["frame"]; print(round(f["x"] + f["width"] - 40), round(f["y"] + f["height"] / 2)); break' "$1"
}

failures=0
check() {  # label, want, got
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; failures=$((failures + 1)); fi
}

# "Fresh install" for the grid order: no pick, no guess, no saved order, no stack.
xcrun simctl terminate "$UDID" "$APP" >/dev/null 2>&1
for k in windowOrderMode windowOrderModeGuess phoneWindowOrderJSON; do
    xcrun simctl spawn "$UDID" defaults delete "$PREFS" "$k" >/dev/null 2>&1
done
for k in $(xcrun simctl spawn "$UDID" defaults export "$PREFS" - 2>/dev/null \
        | python3 -c 'import plistlib,sys; [print(k) for k in plistlib.loads(sys.stdin.buffer.read()) if k.startswith("lastSelectedWindow.")]'); do
    xcrun simctl spawn "$UDID" defaults delete "$PREFS" "$k" >/dev/null 2>&1
done
launch_stamp="$(stamp)"
xcrun simctl launch "$UDID" "$APP" >/dev/null || { echo "FAIL: could not launch Quip"; exit 1; }
wait_for "$LOG" "AUTHENTICATED" 20 || { echo "FAIL: the phone never authenticated (not paired with port $PORT?)"; exit 1; }
sleep 3

check "fresh install guesses Recent" "recent" "$(pref windowOrderModeGuess)"
check "the guess is not a choice" "" "$(pref windowOrderMode)"
check "the guess is not a settings edit" "$launch_stamp" "$(stamp)"

xcrun simctl openurl "$UDID" "quip://window/$SAFARI"
wait_for "$LOG" "frontmost now $SAFARI" 5 || { echo "FAIL: selecting Safari never reached the Mac"; exit 1; }
sleep 1
xcrun simctl openurl "$UDID" "quip://window/$LANTERN"
wait_for "$LOG" "frontmost now $LANTERN" 5 || { echo "FAIL: selecting lantern-web never reached the Mac"; exit 1; }
sleep 2
check "no re-sort while tapping around" "$PINNED $LANTERN $DOTFILES $SAFARI" "$(order)"
come_back
check "Recent order after picking Safari, then lantern-web" "$PINNED $LANTERN $SAFARI $DOTFILES" "$(order)"

before="$(stamp)"
echo "front $SAFARI" >"$WORK/fm.in"
wait_for "$LOG" "cmd front $SAFARI" 5 || { echo "FAIL: the fake Mac did not take 'front'"; exit 1; }
sleep 2
come_back
check "Mac focus moves Safari up" "$PINNED $SAFARI $LANTERN $DOTFILES" "$(order)"
check "a recency write is not a settings edit" "$before" "$(stamp)"

read -r fx fy <<<"$(center "$DOTFILES")"
read -r tx ty <<<"$(center "$SAFARI")"
[ -n "${fx:-}" ] && [ -n "${tx:-}" ] || { echo "FAIL: tiles not found on screen"; exit 1; }
idb ui swipe --udid "$UDID" "$fx" "$fy" "$tx" "$ty" --duration 1.0 --delta 8 >/dev/null
# The toast lives 4 s and an accessibility dump takes about 1 s, so look for
# it first and read the rest from the saved prefs (fast, and still true
# after Use Recent).
bx=""; by=""
for _ in 1 2 3 4; do
    read -r bx by <<<"$(button "Use Recent")"
    [ -n "${bx:-}" ] && break
    sleep 0.3
done
xcrun simctl io "$UDID" screenshot "$SHOTS/q88-s4-manual.png" >/dev/null 2>&1
check "toast offers Use Recent" "yes" "$([ -n "${bx:-}" ] && echo yes || echo no)"
check "drag switches to Manual" "manual" "$(pref windowOrderMode)"
check "the dragged order is saved" "[\"$PINNED\",\"$DOTFILES\",\"$SAFARI\",\"$LANTERN\"]" "$(pref phoneWindowOrderJSON)"

if [ -n "${bx:-}" ]; then
    idb ui tap --udid "$UDID" "$bx" "$by" >/dev/null
    sleep 1
    check "Use Recent switches back" "recent" "$(pref windowOrderMode)"
    check "Recent order is back" "$PINNED $SAFARI $LANTERN $DOTFILES" "$(order)"
    xcrun simctl io "$UDID" screenshot "$SHOTS/q88-s4-recent.png" >/dev/null 2>&1
fi

[ "$failures" = 0 ] && echo "S4 passed; screenshots $SHOTS/q88-s4-manual.png, $SHOTS/q88-s4-recent.png"
exit "$failures"
