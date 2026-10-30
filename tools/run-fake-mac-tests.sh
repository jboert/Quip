#!/usr/bin/env bash
# run-fake-mac-tests.sh — the fake Mac's console commands (Q-88 US-000).
#
# Builds tools/fake-mac/fake-mac.swift, starts it on a free loopback port with
# a FIFO as stdin, connects a minimal WebSocket client that authenticates like
# a phone, then types each command and checks two things: the line the fake
# logs (--log) and what the connected "phone" actually receives. One case per
# command, plus unknown windows (`no such window`, nothing sent).
#
# Needs only xcrun swiftc and python3 (stdlib). Run by tools/check.sh in the
# harness scope.

set -uo pipefail

cd "$(dirname "$0")/.."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/quip-fake-mac-tests.XXXXXX")"
FAKE_PID=""; PROBE_PID=""
cleanup() {
    [ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null
    [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

checks=0
failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

if ! xcrun swiftc -O tools/fake-mac/fake-mac.swift -o "$WORK/fake-mac" 2>"$WORK/build.log"; then
    cat "$WORK/build.log"
    echo "FAIL: tools/fake-mac/fake-mac.swift does not compile"
    exit 1
fi

# A free loopback port the kernel picks; never the real Mac's 8765.
PORT=8765
while [ "$PORT" = "8765" ]; do
    PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
done
PIN=24681357
LOG="$WORK/fake.log"
PROBE_OUT="$WORK/probe.out"
mkfifo "$WORK/fake.in" "$WORK/probe.in"

# `0<>` opens the FIFO read-write, so it never reaches end-of-file between
# commands (a plain `<` would block until the first writer, then hit EOF).
"$WORK/fake-mac" --port "$PORT" --pin "$PIN" --fixture tools/fake-mac/fixture.json --log "$LOG" \
    0<>"$WORK/fake.in" >"$WORK/fake.stdout" 2>&1 &
FAKE_PID=$!

# Minimal RFC 6455 client: authenticates, then writes one summary line per
# message received and sends each JSON line from stdin as a text frame.
cat >"$WORK/probe.py" <<'PY'
import base64, json, os, re, socket, struct, sys, threading

port, pin, out_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
sock = socket.create_connection(("127.0.0.1", port), timeout=10)
key = base64.b64encode(os.urandom(16)).decode()
sock.sendall((f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n"
              f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf:
    chunk = sock.recv(4096)
    if not chunk:
        sys.exit("probe: connection closed during the handshake")
    buf += chunk
head, buf = buf.split(b"\r\n\r\n", 1)
if b" 101 " not in head.split(b"\r\n")[0]:
    sys.exit("probe: handshake refused: " + head.split(b"\r\n")[0].decode())
sock.settimeout(None)
lock = threading.Lock()

def send(obj):
    data = json.dumps(obj).encode()
    mask = os.urandom(4)
    n = len(data)
    if n < 126:
        header = bytes([0x81, 0x80 | n])
    elif n < 65536:
        header = bytes([0x81, 0x80 | 126]) + struct.pack(">H", n)
    else:
        header = bytes([0x81, 0x80 | 127]) + struct.pack(">Q", n)
    with lock:
        sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

def recv_exact(n):
    global buf
    while len(buf) < n:
        chunk = sock.recv(65536)
        if not chunk:
            raise EOFError
        buf += chunk
    data, buf = buf[:n], buf[n:]
    return data

def summary(m):
    t = m.get("type")
    if t == "layout_update":
        return t + " " + " ".join(f"{w['id']}={w['state']}" for w in m["windows"])
    if t == "frontmost_changed":
        return f"{t} {m.get('windowId')}"
    if t == "terminal_content":
        numbered = re.findall(r"^line \d+$", m["content"], re.M)
        first = numbered[0] if numbered else "-"
        last = numbered[-1] if numbered else "-"
        return f"{t} {m['windowId']} numbered={len(numbered)} first={first} last={last}"
    if t == "auth_result":
        return f"{t} success={m.get('success')} error={m.get('error')}"
    return t

def stdin_loop():
    for line in sys.stdin:
        line = line.strip()
        if line:
            send(json.loads(line))

threading.Thread(target=stdin_loop, daemon=True).start()
out = open(out_path, "a", buffering=1)
message = b""
try:
    while True:
        b0, b1 = recv_exact(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", recv_exact(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", recv_exact(8))[0]
        payload = recv_exact(n)
        opcode = b0 & 0x0F
        if opcode == 8:
            break
        if opcode >= 8:
            continue
        message += payload
        if not b0 & 0x80:
            continue
        m = json.loads(message)
        message = b""
        out.write(summary(m) + "\n")
        if m.get("type") == "auth_result" and m.get("error") == "auth_required":
            send({"type": "auth", "pin": pin})
except EOFError:
    pass
PY

# Polls up to 5 s for a line matching an extended regex.
wait_for() {
    local file="$1" pattern="$2" i
    for i in $(seq 1 50); do
        grep -qE -- "$pattern" "$file" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

expect_log() {
    checks=$((checks + 1))
    wait_for "$LOG" "$1" || fail "$2 (no log line matching: $1)"
}

expect_probe() {
    checks=$((checks + 1))
    wait_for "$PROBE_OUT" "$1" || fail "$2 (phone received nothing matching: $1)"
}

# Like expect_probe, but only the newest layout_update counts: the welcome
# layout already matches several of the states checked below.
expect_layout() {
    checks=$((checks + 1))
    local i
    for i in $(seq 1 50); do
        grep -E '^layout_update ' "$PROBE_OUT" 2>/dev/null | tail -1 | grep -qE -- "$1" && return 0
        sleep 0.1
    done
    fail "$2 (newest layout_update does not match: $1)"
}

count() { grep -cE -- "$2" "$1" 2>/dev/null || true; }

cmd() { printf '%s\n' "$1" >"$WORK/fake.in"; }
phone() { printf '%s\n' "$1" >"$WORK/probe.in"; }

# Marks a point in the log: commands run in order, so once `status` has
# answered, every command typed before it has finished.
sync_log() {
    local before; before="$(count "$LOG" '^.*status: ')"
    cmd status
    local i
    for i in $(seq 1 50); do
        [ "$(count "$LOG" '^.*status: ')" -gt "$before" ] && return 0
        sleep 0.1
    done
    fail "the fake stopped answering commands"
    return 1
}

if ! wait_for "$LOG" "fake-mac listening on ws://127.0.0.1:$PORT"; then
    cat "$WORK/fake.stdout"
    echo "FAIL: the fake did not start on port $PORT"
    exit 1
fi

python3 -I "$WORK/probe.py" "$PORT" "$PIN" "$PROBE_OUT" 0<>"$WORK/probe.in" 2>"$WORK/probe.err" &
PROBE_PID=$!
if ! wait_for "$PROBE_OUT" '^frontmost_changed '; then
    cat "$WORK/probe.err"
    echo "FAIL: the probe never authenticated (no welcome frontmost_changed)"
    exit 1
fi

LANTERN=com.googlecode.iterm2.4117
ORCHARD=com.googlecode.iterm2.4101
DOTFILES=com.apple.Terminal.2290

# help and the banner name every new command.
cmd help
for verb in wait idle front open lines; do
    expect_log "^.* +$verb <window>" "help lists $verb"
done
checks=$((checks + 1))
grep -qE 'commands: .*open.*wait idle front lines' "$LOG" || fail "the startup banner lists the new commands"

# wait: neutral fixture window -> waiting_for_input, resent to the phone.
cmd "wait lantern"
expect_log "cmd wait $LANTERN -> state waiting_for_input, layout_update to 1 phone" "wait logs the change"
expect_layout "^layout_update .*$LANTERN=waiting_for_input" "wait reaches the phone as waiting_for_input"

# idle: back to neutral; also turns a fixture-waiting window neutral.
cmd "idle lantern"
expect_layout "^layout_update .*$LANTERN=neutral" "idle puts a waited window back to neutral"
cmd "idle orchard"
expect_log "cmd idle $ORCHARD -> state neutral" "idle logs the change"
expect_layout "^layout_update .*$ORCHARD=neutral" "idle turns a fixture-waiting window neutral"

# front: frontmost_changed for that window; status and later welcomes follow it.
cmd "front dotfiles"
expect_log "cmd front $DOTFILES -> frontmost_changed to 1 phone" "front logs the send"
expect_probe "^frontmost_changed $DOTFILES$" "front reaches the phone"
sync_log
checks=$((checks + 1))
grep -qE "^.* +$DOTFILES .* frontmost" "$LOG" || fail "status marks the frontmost window"

# open: brings back a closed window in the fixture's order.
cmd "close lantern"
expect_layout "^layout_update $ORCHARD=neutral $DOTFILES=" "close drops the window (setup for open)"
cmd "open lantern"
expect_log "cmd open $LANTERN -> layout_update \(4 windows\) to 1 phone" "open logs the change"
expect_layout "^layout_update $ORCHARD=[a-z_]+ $LANTERN=[a-z_]+ $DOTFILES=" "open restores the window in fixture order"

# lines: the next request_content serves N numbered lines; 0 restores.
cmd "lines dotfiles 50"
expect_log "cmd lines $DOTFILES 50 -> the next request_content serves 50 numbered lines" "lines logs the change"
sync_log
phone "{\"type\":\"request_content\",\"windowId\":\"$DOTFILES\"}"
expect_probe "^terminal_content $DOTFILES numbered=50 first=line 0001 last=line 0050$" "lines serves 50 numbered lines"
expect_log "terminal_content \([0-9]+ chars, 0 urls, 50 numbered lines\)" "request_content logs the override"
cmd "lines dotfiles 0"
expect_log "cmd lines $DOTFILES 0 -> the next request_content serves the fixture's content" "lines 0 restores"
cmd "lines dotfiles many"
expect_log "usage: lines <window> <N>" "lines rejects a count that is not a number"

# Unknown windows: `no such window`, and nothing goes to the phone.
sync_log
layouts_before="$(count "$PROBE_OUT" '^layout_update ')"
front_before="$(count "$PROBE_OUT" '^frontmost_changed ')"
for verb in wait idle front open; do
    cmd "$verb nosuch"
    expect_log "$verb: no such window \"nosuch\"" "$verb with an unknown window says no such window"
done
cmd "open orchard"
expect_log "open: no such window \"orchard\" among the closed windows" "open refuses a window that is not closed"
cmd "lines nosuch 5"
expect_log "lines: no such window \"nosuch\"" "lines with an unknown window says no such window"
sync_log
sleep 0.3
checks=$((checks + 1))
[ "$(count "$PROBE_OUT" '^layout_update ')" = "$layouts_before" ] \
    || fail "an unknown window must not resend the layout"
checks=$((checks + 1))
[ "$(count "$PROBE_OUT" '^frontmost_changed ')" = "$front_before" ] \
    || fail "an unknown window must not send frontmost_changed"

# reload forgets every override.
cmd "wait lantern"
expect_layout "^layout_update .*$LANTERN=waiting_for_input" "wait again (setup for reload)"
cmd reload
expect_layout "^layout_update $ORCHARD=waiting_for_input $LANTERN=neutral " "reload restores the fixture's states"

cmd quit
wait "$FAKE_PID" 2>/dev/null
FAKE_PID=""

if [ "$failures" -gt 0 ]; then
    echo "fake-mac tests: $failures of $checks checks FAILED (log: kept below)"
    tail -40 "$LOG"
    exit 1
fi
echo "fake-mac tests: $checks checks passed"
