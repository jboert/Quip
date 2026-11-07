#!/usr/bin/env bash
# q91-pair.sh — Q-91 spec 10.6: pair the iPhone app with the Windows host by
# PIN. The backend row appears and the grid shows the fixture's terminals
# with app names (Windows Terminal, PowerShell, Command Prompt), no folder,
# and not the Notepad window (not a terminal).
#
#   tools/qa/q91-pair.sh <simulator-udid> [port] [screenshot-dir]
#
# Needs: Quip installed on that simulator, idb, cargo. Starts its own fake
# Windows host (`Quip --fake-platform`) on `port` (default 8797) and pairs
# through the quip://pair link with the fake's PIN. Removes the fake-windows
# row (device id ...0002) from the phone first, so the row must come from this
# pairing; other rows are left alone. Use a simulator of your own.
#
# Evidence: <screenshot-dir>/s5-q91-pair.png (default docs/superpowers/evidence/q91).

UDID="${1:?usage: q91-pair.sh <simulator-udid> [port] [screenshot-dir]}"
PORT="${2:-8797}"
SHOTS="$(mkdir -p "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && cd "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && pwd)"
NAME=q91-pair
. "$(dirname "$0")/q91-lib.sh"

q91_start_fake

# Forget the fake-windows backend, so pairing has to add it back.
xcrun simctl terminate "$UDID" "$APP" >/dev/null 2>&1
PREFS="$(q91_prefs)" || { echo "FAIL: Quip is not installed on $UDID"; exit 1; }
rows() {  # the paired rows as "id url"
    xcrun simctl spawn "$UDID" defaults export "$PREFS" - 2>/dev/null | python3 -c '
import json, plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
for r in json.loads(d.get("pairedBackendsData", b"[]")):
    print(r["id"], r["url"])'
}
xcrun simctl spawn "$UDID" defaults export "$PREFS" - 2>/dev/null | python3 -c '
import json, plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
fid, mid, port = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [r for r in json.loads(d.get("pairedBackendsData", b"[]")) if r["id"] != fid]
d["pairedBackendsData"] = json.dumps(rows).encode()
recents = [r for r in json.loads(d.get("recentConnectionsData", b"[]")) if not r["url"].endswith(":" + port)]
d["recentConnectionsData"] = json.dumps(recents).encode()
if d.get("activeBackendID") == fid:
    d["activeBackendID"] = mid
sys.stdout.buffer.write(plistlib.dumps(d))' "$FAKE_WIN_ID" "$FAKE_MAC_ID" "$PORT" >"$WORK/prefs.plist"
xcrun simctl spawn "$UDID" defaults import "$PREFS" - <"$WORK/prefs.plist"
check "fake-windows row removed before pairing" "" "$(rows | grep "$FAKE_WIN_ID")"

q91_pair
expect "host logged auth ok" grep -q 'auth ok from 127.0.0.1' "$LOGS/websocket.log"
check "the fake counts one phone" "phones authenticated: 1" "$(fw status; sleep 1; grep 'phones authenticated' "$ERR" | tail -1)"

# The grid: app names and window titles of the four terminals.
for want in "Windows Terminal" "PowerShell" "Command Prompt" "pwsh in orchar" "pebble-docs"; do
    expect "grid shows '$want'" on_screen "$want" 10
done
shot s5-q91-pair
ocr "$SHOTS/s5-q91-pair.png" >"$WORK/screen.txt"
check "Notepad (not a terminal) is not in the grid" "" "$(grep -E 'Notepad|notes\.txt' "$WORK/screen.txt")"
check "no folder on the cards" "" "$(grep -E '~/|[A-Z]:\\\\' "$WORK/screen.txt")"

# The row: saved with the fake's device id and URL.
sleep 1
check "paired row saved" "$FAKE_WIN_ID ws://127.0.0.1:$PORT" "$(rows | grep "$FAKE_WIN_ID")"

finish "$SHOTS/s5-q91-pair.png"
