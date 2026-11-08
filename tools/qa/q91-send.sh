#!/usr/bin/env bash
# q91-send.sh — Q-91 spec 10.6: text + Return from the phone reaches the
# Windows host as typing, then Return; multi-line text shows the guard.
#
#   tools/qa/q91-send.sh <simulator-udid> [port] [screenshot-dir]
#
# Needs: Quip installed on that simulator, idb, cargo. Starts its own fake
# Windows host on `port` (default 8797) and pairs by the PIN link.
#
# Three sends, each checked on the fake's action lines and latency.log:
#  1. one line typed in the compose field into PowerShell: `type units=N`,
#     then `chord=return`; latency.log `send_text ... success=1 press_return=1`.
#     (Typed, not dictated: the simulator has no microphone. Dictation ends
#     in the same send_text.)
#  2. a multi-line prompt (a quip://share review sheet, the phone's own
#     multi-line path) into PowerShell: Shift+Enter between lines and no
#     Return; latency.log `multiline_guard=1`.
#  3. the same into Command Prompt: refused, nothing typed into cmd, the
#     refusal in injection.log (DROPPED) and its reason on the phone.
#  4. (S11, spec 5.4 step 2b) `fw elevated 4117 on`, then one line into
#     PowerShell: nothing typed (no `type handle=4117`), injection.log
#     `detail="input blocked (elevated window?)"`, the phone shows the
#     "administrator" reason. `fw elevated 4117 off` after.
#
# Evidence: <screenshot-dir>/s5-q91-send.png (the cmd refusal on the phone),
# <screenshot-dir>/s11-q91-send.png (the elevated refusal).

UDID="${1:?usage: q91-send.sh <simulator-udid> [port] [screenshot-dir]}"
PORT="${2:-8797}"
SHOTS="$(mkdir -p "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && cd "${3:-$(dirname "$0")/../../docs/superpowers/evidence/q91}" && pwd)"
NAME=q91-send
. "$(dirname "$0")/q91-lib.sh"

q91_start_fake
q91_pair
LAT="$LOGS/latency.log"
lat_lines() { [ -f "$LAT" ] && wc -l <"$LAT" | tr -d ' ' || echo 0; }

select_window() {  # wire id, handle
    xcrun simctl openurl "$UDID" "quip://window/$1"
    wait_for "$OUT" "focus handle=$2 " 5 || { echo "FAIL: selecting $1 never focused handle $2"; exit 1; }
    sleep 1
}

# The blue send arrow right of the compose field (an icon, so found by colour).
send_button() {
    xcrun simctl io "$UDID" screenshot "$WORK/s.png" >/dev/null 2>&1
    python3 - "$WORK/s.png" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
for y in range(120 * 3, 600 * 3, 3):
    r, g, b = im.getpixel((420 * 3, y))
    if b > 200 and r < 60 and 100 < g < 170:
        print(420, y // 3 + 8)
        break
EOF
}

share_send() {  # send a multi-line prompt through the share review sheet
    xcrun simctl openurl "$UDID" "quip://share?title=q91%20multi-line%20check"
    sleep 2
    xcrun simctl io "$UDID" screenshot "$WORK/sheet.png" >/dev/null 2>&1
    local xy
    xy="$(ocr "$WORK/sheet.png" | awk '$3 == "Send" && NF == 3 && $2 < 200 {print $1, $2; exit}')"
    [ -n "$xy" ] || { echo "FAIL: the share review sheet did not open"; exit 1; }
    idb ui tap --udid "$UDID" $xy >/dev/null
    sleep "${SHARE_WAIT:-2}"
}

compose_send() {  # type $1 in the compose field and tap send; sets mark, lmark
    xcrun simctl io "$UDID" screenshot "$WORK/field.png" >/dev/null 2>&1
    local xy bx by
    xy="$(ocr "$WORK/field.png" | awk '/Type a prompt/ {print $1, $2; exit}')"
    [ -n "$xy" ] || { echo "FAIL: the compose field is not on screen"; exit 1; }
    idb ui tap --udid "$UDID" $xy >/dev/null
    sleep 0.7
    idb ui text --udid "$UDID" "$1" >/dev/null
    sleep 0.7
    mark=$(lines); lmark=$(lat_lines)
    read -r bx by <<<"$(send_button)"
    [ -n "${bx:-}" ] || { echo "FAIL: no send button found"; exit 1; }
    idb ui tap --udid "$UDID" "$bx" "$by" >/dev/null
}

# 1. One line into PowerShell (handle 4117).
select_window "$W_POWERSHELL" 4117
TEXT="echo q91-send"
compose_send "$TEXT"
wait_for "$OUT" "key handle=4117 chord=return" 5
sleep 0.5
got="$(since "$mark" | grep -E 'handle=4117 (units|chord)|type handle=4117|key handle=4117' | sed 's/^fake: //' | paste -sd'|' -)"
check "one line: text, then Return" "type handle=4117 units=${#TEXT}|key handle=4117 chord=return" "$got"
expect "one line: latency.log send_text success=1 press_return=1 text_len=${#TEXT}" \
    grep -qE "send_text .*shell=powershell success=1 text_len=${#TEXT} segments=1 press_return=1" <(tail -n +$((lmark + 1)) "$LAT")

# Put the keyboard away before the share sheet.
idb ui key --udid "$UDID" 41 >/dev/null 2>&1
sleep 1

# 2. Multi-line into PowerShell: Shift+Enter inner breaks, never Return.
mark=$(lines); lmark=$(lat_lines)
share_send
new="$(since "$mark")"
check "multi-line: Shift+Enter between lines" "yes" "$(grep -q 'key handle=4117 chord=shift+return' <<<"$new" && echo yes || echo no)"
check "multi-line: text typed" "yes" "$(grep -q 'type handle=4117 units=' <<<"$new" && echo yes || echo no)"
check "multi-line: no Return" "" "$(grep 'chord=return' <<<"$new")"
expect "multi-line: latency.log multiline_guard=1 success=1" \
    grep -qE "send_text .*shell=powershell success=1 .*multiline_guard=1" <(tail -n +$((lmark + 1)) "$LAT")

# 3. Multi-line into Command Prompt (handle 4133): refused, with the host's
#    reason on the phone.
select_window "$W_CMD" 4133
idb ui key --udid "$UDID" 41 >/dev/null 2>&1
sleep 1
mark=$(lines); imark=$([ -f "$LOGS/injection.log" ] && wc -l <"$LOGS/injection.log" | tr -d ' ' || echo 0)
SHARE_WAIT=0 share_send
expect "cmd multi-line: the phone shows the refusal" on_screen "sent safely|one line at a time" 6
cp "$WORK/poll.png" "$SHOTS/s5-q91-send.png"
sleep 1
new="$(since "$mark")"
check "cmd multi-line: nothing typed or pressed" "" "$(grep -E '(type|key) handle=4133' <<<"$new")"
expect "cmd multi-line: injection.log DROPPED multi-line text refused" \
    grep -qE "DROPPED op=sendText window=$W_CMD .*msg=\"multi-line text refused\"" <(tail -n +$((imark + 1)) "$LOGS/injection.log")

# 4. An elevated PowerShell (integrity above Quip's): nothing typed, the
#    "administrator" reason on the phone.
fw elevated 4117 on
idb ui key --udid "$UDID" 41 >/dev/null 2>&1
sleep 0.5
select_window "$W_POWERSHELL" 4117
imark=$([ -f "$LOGS/injection.log" ] && wc -l <"$LOGS/injection.log" | tr -d ' ' || echo 0)
compose_send "echo q91-elevated"
wait_for "$OUT" "access handle=4117 elevated" 5
expect "elevated: the phone shows the administrator reason" on_screen "administrator" 6
cp "$WORK/poll.png" "$SHOTS/s11-q91-send.png"
sleep 0.5
new="$(since "$mark")"
check "elevated: the host asked the integrity level" "yes" "$(grep -q 'access handle=4117 elevated' <<<"$new" && echo yes || echo no)"
check "elevated: nothing typed or pressed" "" "$(grep -E '(type|key) handle=4117' <<<"$new")"
expect "elevated: injection.log input blocked (elevated window?)" \
    grep -qE "DROPPED op=sendText window=$W_POWERSHELL .*detail=\"input blocked \(elevated window\?\)\"" <(tail -n +$((imark + 1)) "$LOGS/injection.log")
expect "elevated: latency.log success=0" \
    grep -qE "send_text .*success=0" <(tail -n +$((lmark + 1)) "$LAT")
fw elevated 4117 off

finish "$SHOTS/s5-q91-send.png" "$SHOTS/s11-q91-send.png"
