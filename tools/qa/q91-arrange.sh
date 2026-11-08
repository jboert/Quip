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
# S10 (spec 5.2: restore, measure, move, verify, retry), on the fake's lines,
# its logs and the layout_update / error frames the scripted peer receives:
#   (a) `minimize 4133`, then horizontal: `fake: restore handle=4133` comes
#       before its `fake: move`, and the peer's layout_update has it
#       isMinimized:false in its column;
#   (b) `refuse-move 4149 on`, then vertical: the peer gets
#       "Windows refused to move 1 of 4 windows (elevated or protected)",
#       injection.log has op=arrange with detail="elevated or refused", and
#       the other three moved;
#   (c) `rescale 4101 125`, then horizontal: two `fake: move handle=4101`
#       lines, the second at its column rect.
# How the phone shows an `error` without a messageId is not asserted.
#
# Evidence: <screenshot-dir>/s10-q91-arrange.png.

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

# S10 checks on one arrange: the fake's move/restore lines since the mark and
# the frames the scripted peer received. The layout_update windows are the
# broadcast set in broadcast order, so window i of n owns column i of the
# 1920 px work area (frames are normalized against the 1920 px primary).
s10_check() {  # case, moves file, peer file, handle
    python3 - "$@" <<'EOF'
import json, re, sys
case, moves_path, peer_path, handle = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
WIRE = {4101: "w-1005-13ed-1", 4117: "w-1015-13fd-2", 4133: "w-1025-140d-3", 4149: "w-1035-141d-4"}
lines = [l.rstrip("\n") for l in open(moves_path)]
frames = []
for l in open(peer_path):
    try:
        frames.append(json.loads(l.split(" ", 1)[1]))
    except (IndexError, ValueError):
        pass
layouts = [f for f in frames if f.get("type") == "layout_update"]
errors = [f for f in frames if f.get("type") == "error"]
problems = []

def moves_of(h):
    out = []
    for l in lines:
        m = re.search(rf"^fake: move handle={h} outer=(-?\d+),(-?\d+) (\d+)x(\d+)$", l)
        if m:
            out.append(tuple(int(v) for v in m.groups()))
    return out

def column(h, msg):
    ids = [w["id"] for w in msg["windows"]]
    return ids.index(WIRE[h]), len(ids)

if case == "a":
    r = [i for i, l in enumerate(lines) if l == f"fake: restore handle={handle}"]
    m = [i for i, l in enumerate(lines) if l.startswith(f"fake: move handle={handle} ")]
    if not r:
        problems.append("no restore line")
    elif not m:
        problems.append("no move line")
    elif r[0] > m[0]:
        problems.append("moved before it was restored")
    if errors:
        problems.append(f"error frames: {errors}")
    if len(layouts) < 2:
        problems.append(f"{len(layouts)} layout_update frames, want the handshake one and the arranged one")
    else:
        last = layouts[-1]
        w = next((w for w in last["windows"] if w["id"] == WIRE[handle]), None)
        if w is None:
            problems.append("not in the layout")
        elif w["isMinimized"]:
            problems.append("still minimized")
        else:
            i, n = column(handle, last)
            x, width = w["frame"]["x"] * 1920, w["frame"]["width"] * 1920
            if abs(x - i * 1920 / n) > 1 or abs(width - 1920 / n) > 1:
                problems.append(f"x={x:.1f} width={width:.1f}, want column {i} of {n}")
elif case == "b":
    want = "Windows refused to move 1 of 4 windows (elevated or protected)"
    if [e.get("reason") for e in errors] != [want]:
        problems.append(f"errors {errors}")
    moved = sorted({int(re.search(r"handle=(\d+)", l)[1]) for l in lines if re.match(r"^fake: move handle=\d+ ", l)})
    if moved != sorted(set(WIRE) - {handle}):
        problems.append(f"moved {moved}")
    if f"fake: move REFUSED handle={handle}" not in lines:
        problems.append("no refusal line")
elif case == "c":
    ms = moves_of(handle)
    if len(ms) != 2:
        problems.append(f"{len(ms)} moves of {handle}: {ms}")
    elif errors:
        problems.append(f"error frames: {errors}")
    elif not layouts:
        problems.append("no layout_update")
    else:
        i, n = column(handle, layouts[-1])
        want = (round(i * 1920 / n) - 7, 0, round(1920 / n) + 14, 1047)
        if ms[1] != want:
            problems.append(f"second move {ms[1]}, want the column rect {want}")
print("; ".join(problems) or "ok")
EOF
}

s10_arrange() {  # case, layout, handle
    local mark
    mark=$(lines)
    : >"$WORK/peer-s10-$1.txt"
    peer 3 "$WORK/peer-s10-$1.txt" "{\"type\":\"arrange_windows\",\"layout\":\"$2\"}"
    since "$mark" | grep -E '^fake: (move|restore) ' >"$WORK/moves-s10-$1.txt"
    sed 's/^/     /' "$WORK/moves-s10-$1.txt" >&2
    s10_check "$1" "$WORK/moves-s10-$1.txt" "$WORK/peer-s10-$1.txt" "$3"
}

fw minimize 4133
sleep 0.5
check "(a) a minimized window is restored before it is measured, then tiled" ok "$(s10_arrange a horizontal 4133)"

fw refuse-move 4149 on
sleep 0.3
check "(b) one refused window is reported and the other three move" ok "$(s10_arrange b vertical 4149)"
check "(b) injection.log names the refusal" 1 \
    "$(grep -c 'op=arrange .*detail="elevated or refused"' "$LOGS/injection.log" 2>/dev/null)"
fw refuse-move 4149 off

fw rescale 4101 125
sleep 0.3
check "(c) a rescaled window gets one more move, to its column" ok "$(s10_arrange c horizontal 4101)"

expect "the phone shows the four cards after the S10 arranges" on_screen "Command Prompt" 4
cp "$WORK/poll.png" "$SHOTS/s10-q91-arrange.png"

finish "$SHOTS/s10-q91-arrange.png"
