#!/usr/bin/env bash
# q91-layout.sh — Q-91 spec 10.6: when windows change on the PC (one added,
# retitled, moved, removed), the phone's grid follows within 2 s.
#
#   tools/qa/q91-layout.sh <simulator-udid> [port] [screenshot-dir]
#
# Needs: Quip installed on that simulator, idb, cargo. Starts its own fake
# Windows host on `port` (default 8797) and pairs by the PIN link.
#
# Drives the fake's own commands (open, title, move, close) and times, from
# the command to the first screenshot showing it (read by OCR):
#   open  "q91 added window"   -> the new card's title is on screen
#   title -> "q91 renamed"     -> the card shows the new title
#   close                      -> the card is gone
# A move does not change the phone's grid (cards are not drawn at their PC
# positions), so it is checked on the wire: a scripted second client gets a
# layout_update with Command Prompt's new frame within 2 s.
#
# Evidence: <screenshot-dir>/s5-q91-layout.png (the grid with the added,
# renamed window).

UDID="${1:?usage: q91-layout.sh <simulator-udid> [port] [screenshot-dir]}"
PORT="${2:-8797}"
SHOTS="$(mkdir -p "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && cd "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && pwd)"
NAME=q91-layout
. "$(dirname "$0")/q91-lib.sh"

q91_start_fake
q91_pair
on_screen "pwsh in orchar" 10 || { echo "FAIL: the grid never showed the fixture"; exit 1; }

within() {  # label seconds-or-empty
    if [ -z "$2" ]; then echo "FAIL $1: not seen within 4 s"; failures=$((failures + 1)); return; fi
    if python3 -c "import sys; sys.exit(0 if $2 <= 2.0 else 1)"; then
        echo "ok   $1 (${2} s)"
    else
        echo "FAIL $1: took ${2} s, want <= 2 s"; failures=$((failures + 1))
    fi
}

fw open q91 added window
within "added window appears" "$(screen_has "q91 added" 4)"

fw title q91 q91 renamed
within "retitle shows" "$(screen_has "q91 renamed" 4)"
cp "$WORK/poll.png" "$SHOTS/s5-q91-layout.png"

# Move Command Prompt from the second display onto the primary one.
peer 6 "$WORK/peer.txt" &
PEER=$!
sleep 1.5
t_move="$(python3 -c 'import time; print(time.time())')"
fw move 4133 100 100 800 500
wait "$PEER"
moved="$(python3 - "$WORK/peer.txt" "$W_CMD" "$t_move" <<'EOF'
import json, sys
path, wid, t_move = sys.argv[1], sys.argv[2], float(sys.argv[3])
# The first layout_update (on auth) is the before; the move answers at once,
# so the next one with a different frame may carry a time a hair before
# t_move.
before, after_t, after = None, None, None
for line in open(path):
    t, msg = line.split(" ", 1)
    m = json.loads(msg)
    if m.get("type") != "layout_update":
        continue
    frame = next((w["frame"] for w in m["windows"] if w["id"] == wid), None)
    if before is None:
        before = frame
    elif after is None and frame != before:
        after_t, after = float(t), frame
if before is None or after is None:
    print("none")
else:
    print(f"{max(0.0, after_t - t_move):.1f}")
EOF
)"
[ "$moved" = none ] && moved=""
within "move reaches the phone's layout_update" "$moved"

fw close q91
within "closed window disappears" "$(screen_has ! "q91 renamed" 4)"
on_screen "pwsh in orchar" 2 || { echo "FAIL the fixture's cards went away too"; failures=$((failures + 1)); }

finish "$SHOTS/s5-q91-layout.png"
