# q91-lib.sh — shared helpers for the tools/qa/q91-*.sh scenario scripts.
# Sourced, never run. Each script drives the real iPhone app in a simulator
# against the Windows host's fake platform (`Quip --fake-platform`,
# tools/fake-windows/README.md), spec 2026-11-06-q91 section 10.6.
#
# The caller sets UDID, PORT and SHOTS (defaults: port 8797, screenshots in
# docs/superpowers/evidence/q91/) and NAME (the script's short name).
#
# What it gives the script:
#   q91_start_fake        build and start the fake on $PORT, logs in $WORK/logs
#   fw <command>          type a command into the fake (status, move, open, ...)
#   q91_pair              pair the phone by the PIN link and wait for "auth ok"
#   wait_for f re secs    wait until file f has a line matching re
#   shot NAME             screenshot to $SHOTS/NAME.png
#   ocr FILE              text on a screenshot, one "x y text" line per item,
#                         in points (the screenshot is 3 px per point)
#   screen_has re secs    poll screenshots until the OCR text matches re
#                         (prints the seconds it took; on_screen is quiet)
#   peer secs out [json]  a scripted second client (see below)
#   check label want got  record a pass or a failure
#   finish                print the result and exit with the failure count
#
# Safety (tools/fake-windows/README.md): the fake binds 127.0.0.1 only and
# refuses port 8765. Use a simulator of your own, never D8C5154B while another
# session gates on it.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

APP=com.fintechadventures.quip
PIN=11112222
FAKE_WIN_ID=FA4E3AC0-0000-4000-8000-000000000002
FAKE_MAC_ID=FA4E3AC0-0000-4000-8000-000000000001
# Wire ids the fixture's windows get (w-<handle hex>-<pid hex>-<seq>).
W_ORCHARD=w-1005-13ed-1     # pwsh in orchard-api (Windows Terminal, pwsh)
W_POWERSHELL=w-1015-13fd-2  # Windows PowerShell (conhost)
W_CMD=w-1025-140d-3         # Command Prompt (cmd: multi-line refused)
W_PEBBLE=w-1035-141d-4      # pebble-docs (mixed tabs: shell unknown)

[ "$PORT" = 8765 ] && { echo "FAIL: 8765 is the real app's port"; exit 2; }
mkdir -p "$SHOTS"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/q91-$NAME.XXXXXX")"
LOGS="$WORK/logs"
OUT="$WORK/fw.out"   # the fake's stdout: one "fake: ..." line per platform action
ERR="$WORK/fw.err"   # its stderr: banner, command replies
FAKE_PID=""
EXTRA_CLEANUP=""
cleanup() {
    [ -n "$EXTRA_CLEANUP" ] && eval "$EXTRA_CLEANUP"
    [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
    wait 2>/dev/null
    if [ -n "${KEEP_WORK:-}" ]; then echo "work dir kept: $WORK"; else rm -rf "$WORK"; fi
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

fw() { echo "$*" >"$WORK/fw.in"; }

q91_start_fake() {
    cargo build --quiet --manifest-path QuipWindows/Cargo.toml || { echo "FAIL: QuipWindows did not build"; exit 1; }
    mkfifo "$WORK/fw.in"
    mkdir -p "$LOGS"
    QuipWindows/target/debug/Quip --fake-platform --port "$PORT" --pin "$PIN" \
        --fixture tools/fake-windows/fixture.json --log-dir "$LOGS" \
        0<>"$WORK/fw.in" >"$OUT" 2>"$ERR" &
    FAKE_PID=$!
    wait_for "$ERR" "fake-windows listening on 127.0.0.1:$PORT" 10 \
        || { echo "FAIL: the fake did not start:"; cat "$ERR"; exit 1; }
    ocr_build
}

# OCR with Vision, built once per run into $WORK.
ocr_build() {
    cat >"$WORK/ocr.swift" <<'EOF'
import Foundation
import Vision
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(2) }
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: img).perform([req])
let w = Double(img.width) / 3, h = Double(img.height) / 3
for o in req.results ?? [] {
    guard let t = o.topCandidates(1).first else { continue }
    let b = o.boundingBox
    print(Int(b.midX * w), Int((1 - b.midY) * h), t.string)
}
EOF
    xcrun swiftc -O "$WORK/ocr.swift" -o "$WORK/ocr" 2>/dev/null || { echo "FAIL: could not build the OCR helper"; exit 1; }
}
ocr() { "$WORK/ocr" "$1"; }

shot() {  # name -> $SHOTS/name.png
    xcrun simctl io "$UDID" screenshot "$SHOTS/$1.png" >/dev/null 2>&1
}

# Poll the screen until its text matches (or, with "!", stops matching) a regex.
# Prints the seconds from the call to the start of the screenshot that showed it.
screen_has() {  # [!] regex seconds
    local negate=""; [ "$1" = "!" ] && { negate=1; shift; }
    local t0 now deadline
    t0="$(python3 -c 'import time; print(time.time())')"
    deadline="$(python3 -c "print($t0 + $2)")"
    while :; do
        now="$(python3 -c 'import time; print(time.time())')"
        xcrun simctl io "$UDID" screenshot "$WORK/poll.png" >/dev/null 2>&1
        if ocr "$WORK/poll.png" | grep -qE -- "$1"; then
            [ -z "$negate" ] && { python3 -c "print(f'{$now - $t0:.1f}')"; return 0; }
        else
            [ -n "$negate" ] && { python3 -c "print(f'{$now - $t0:.1f}')"; return 0; }
        fi
        python3 -c "import sys; sys.exit(0 if $now < $deadline else 1)" || return 1
        sleep 0.2
    done
}

on_screen() { screen_has "$@" >/dev/null; }

# A second, scripted client of the fake (stdlib only): authenticates with the
# PIN, sends each JSON argument, and writes every text frame it receives, one
# per line as "<unix time> <json>", to OUTFILE for SECONDS. Used where the
# iPhone app has no button for a message (arrange_windows) and to read the
# layout_update the phone got.
peer() {  # seconds outfile [json ...]
    python3 - "$PORT" "$PIN" "$@" <<'EOF'
import base64, json, os, socket, struct, sys, time
port, pin, secs, out, sends = int(sys.argv[1]), sys.argv[2], float(sys.argv[3]), sys.argv[4], sys.argv[5:]
s = socket.create_connection(("127.0.0.1", port), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
buf = buf.split(b"\r\n\r\n", 1)[1]
def send(text):
    data, mask = text.encode(), os.urandom(4)
    n = len(data)
    head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n))
    s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
def frames():
    global buf
    while True:
        while len(buf) >= 2:
            op, n, i = buf[0] & 0x0F, buf[1] & 0x7F, 2
            if n == 126: n, i = struct.unpack(">H", buf[2:4])[0], 4
            elif n == 127: n, i = struct.unpack(">Q", buf[2:10])[0], 10
            if len(buf) < i + n: break
            payload, buf = buf[i:i + n], buf[i + n:]
            if op == 1: yield payload.decode()
            elif op == 9: s.sendall(bytes([0x8A, 0x80]) + os.urandom(4))
        chunk = s.recv(65536)
        if not chunk: return
        buf += chunk
send(json.dumps({"type": "auth", "pin": pin}))
s.settimeout(secs)
deadline = time.time() + secs
sent = False
with open(out, "a") as f:
    try:
        for t in frames():
            f.write(f"{time.time():.2f} {t}\n"); f.flush()
            if not sent and '"auth_result"' in t and '"success":true' in t.replace(" ", ""):
                for m in sends: send(m)
                sent = True
            s.settimeout(max(0.1, deadline - time.time()))
            if time.time() > deadline: break
    except (socket.timeout, OSError):
        pass
EOF
}

# Answer iOS's "Open in Quip?" if it shows, by tapping its Open button.
tap_open_prompt() {
    xcrun simctl io "$UDID" screenshot "$WORK/prompt.png" >/dev/null 2>&1
    local xy
    xy="$(ocr "$WORK/prompt.png" | awk '$3 == "Open" && NF == 3 {print $1, $2; exit}')"
    [ -n "$xy" ] && idb ui tap --udid "$UDID" $xy >/dev/null 2>&1
    return 0
}

pair_link() {  # port -> quip://pair link for ws://127.0.0.1:port
    printf 'quip://pair?url=%s&pin=%s' "$(printf 'ws://127.0.0.1:%s' "$1" | base64 | tr -d '=')" "$PIN"
}

# Launch the app and pair it with the fake by the PIN link. Waits for the
# host's own "auth ok" line, then for the first layout to land.
q91_pair() {
    xcrun simctl terminate "$UDID" "$APP" >/dev/null 2>&1
    xcrun simctl launch "$UDID" "$APP" >/dev/null || { echo "FAIL: Quip is not installed on $UDID"; exit 1; }
    sleep 2
    xcrun simctl openurl "$UDID" "$(pair_link "$PORT")"
    sleep 1
    tap_open_prompt
    wait_for "$LOGS/websocket.log" "auth ok from 127.0.0.1" 20 \
        || { echo "FAIL: the phone never authenticated with the fake on $PORT"; exit 1; }
    sleep 2
}

# The app's preferences (simctl defaults on the app's own plist).
q91_prefs() { echo "$(xcrun simctl get_app_container "$UDID" "$APP" data)/Library/Preferences/$APP"; }

failures=0
check() {  # label, want, got
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; failures=$((failures + 1)); fi
}
expect() {  # label, then a command that must succeed
    local label="$1"; shift
    if "$@"; then echo "ok   $label"; else echo "FAIL $label"; failures=$((failures + 1)); fi
}
# New lines of the fake's stdout since a mark (`mark=$(lines)`).
lines() { wc -l <"$OUT" | tr -d ' '; }
since() { tail -n +$(($1 + 1)) "$OUT"; }

finish() {
    if [ "$failures" = 0 ]; then echo "$NAME passed; evidence $*"; else echo "$NAME FAILED ($failures)"; fi
    exit "$failures"
}
