#!/usr/bin/env bash
# q91-arrange.sh — Q-91 spec 10.6: arrange_windows side by side
# (`horizontal`) and stacked (`vertical`) tiles the windows the phone is
# shown, on the primary display's work area.
#
#   tools/qa/q91-arrange.sh <simulator-udid> [port] [screenshot-dir]
#
# Needs: Quip installed on that simulator, idb, cargo. Starts its own fake
# Windows host on `port` (default 8797) and pairs the phone by the PIN link.
#
# The iPhone app (1.5.7) has no control that sends arrange_windows: its
# Arrange button only re-lays out the phone's own grid. So the message comes
# from a scripted second client of the fake, while the paired phone watches.
# Checked per layout, on the fake's `fake: move` lines:
#   - exactly the four terminals move (4101, 4117, 4133, 4149), not Notepad;
#   - horizontal: four columns, one top edge, equal widths, left to right
#     across the 1920 px work area;
#   - vertical: four rows, one left edge, equal heights, top to bottom;
# and the phone still shows the four cards afterwards (screenshot).
#
# Evidence: <screenshot-dir>/s5-q91-arrange.png.

UDID="${1:?usage: q91-arrange.sh <simulator-udid> [port] [screenshot-dir]}"
PORT="${2:-8797}"
SHOTS="$(mkdir -p "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && cd "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && pwd)"
NAME=q91-arrange
. "$(dirname "$0")/q91-lib.sh"

q91_start_fake
q91_pair
on_screen "pwsh in orchar" 10 || { echo "FAIL: the grid never showed the fixture"; exit 1; }

arrange() {  # layout
    local mark
    mark=$(lines)
    peer 3 "$WORK/peer-$1.txt" "{\"type\":\"arrange_windows\",\"layout\":\"$1\"}"
    since "$mark" | grep '^fake: move ' >"$WORK/moves-$1.txt"
    sed 's/^/     /' "$WORK/moves-$1.txt"
    python3 - "$1" "$WORK/moves-$1.txt" <<'EOF'
import re, sys
layout, path = sys.argv[1], sys.argv[2]
moves = {}
for line in open(path):
    m = re.search(r"handle=(\d+) outer=(-?\d+),(-?\d+) (\d+)x(\d+)", line)
    if m:
        moves[int(m[1])] = tuple(int(v) for v in m.groups()[1:])
problems = []
if sorted(moves) != [4101, 4117, 4133, 4149]:
    problems.append(f"moved handles {sorted(moves)}, want the four terminals")
rects = sorted(moves.values(), key=lambda r: (r[0], r[1]) if layout == "horizontal" else (r[1], r[0]))
if layout == "horizontal":
    if len({r[1] for r in rects}) != 1: problems.append("columns do not share a top edge")
    if len({r[2] for r in rects}) != 1: problems.append("columns differ in width")
    if any(b[0] <= a[0] for a, b in zip(rects, rects[1:])): problems.append("columns overlap in x")
    if rects and not (rects[-1][0] + rects[-1][2] - 7 >= 1910): problems.append("columns do not reach the right edge")
else:
    if len({r[0] for r in rects}) != 1: problems.append("rows do not share a left edge")
    if len({r[3] for r in rects}) != 1: problems.append("rows differ in height")
    if any(b[1] <= a[1] for a, b in zip(rects, rects[1:])): problems.append("rows overlap in y")
    if rects and not (rects[-1][1] + rects[-1][3] - 7 >= 1030): problems.append("rows do not reach the bottom")
print("; ".join(problems) or "ok")
EOF
}

check "arrange horizontal tiles the four terminals side by side" ok "$(arrange horizontal | tee /dev/stderr | tail -1)"
check "arrange vertical stacks the four terminals" ok "$(arrange vertical | tee /dev/stderr | tail -1)"
expect "the phone still shows the four cards" on_screen "Command Prompt" 4
cp "$WORK/poll.png" "$SHOTS/s5-q91-arrange.png"

finish "$SHOTS/s5-q91-arrange.png"
