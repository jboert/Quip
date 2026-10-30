#!/usr/bin/env bash
# Q-90 — tests for QuipMac/Resources/quip-watchdog.sh, run by tools/check.sh's
# harness block. Table tests of the pure decision (each guard on both sides),
# the same table against a deliberately broken fixture (which MUST fail), and
# an integration run that kills a real process.
#
# The table runs under dash, the strictest POSIX shell on a stock Mac, so a
# bashism in the script fails here rather than under launchd's /bin/sh.
set -uo pipefail

cd "$(dirname "$0")/.."

SCRIPT="QuipMac/Resources/quip-watchdog.sh"
BROKEN="tools/tests/fixtures/quip-watchdog-broken.sh"
POSIX_SH=/bin/dash
[ -x "$POSIX_SH" ] || POSIX_SH=/bin/sh

checks=0
failures=0
table_failures=0

check() {
    local label="$1" want="$2" got="$3"
    checks=$((checks + 1))
    if [ "$got" != "$want" ]; then
        echo "FAIL: $label — want '$want', got '$got'"
        failures=$((failures + 1))
    fi
}

# Every call is fenced in: a mutant that ignores QUIP_WD_SOURCE_ONLY and runs
# the main path must find a pid that is not Quip and state under $TMPDIR, never
# `pgrep -x Quip` and the owner's real heartbeat.
FENCE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/quip-wd-fence.XXXXXX")
FENCE=(PATH="$PATH" HOME="$FENCE_DIR" QUIP_WD_SOURCE_ONLY=1 QUIP_WD_PID=999999
       QUIP_WD_STATE_DIR="$FENCE_DIR" QUIP_WD_LOG_DIR="$FENCE_DIR" QUIP_WD_SAMPLE=/usr/bin/true)

# Run one shell function from FILE (sourced with QUIP_WD_SOURCE_ONLY=1)
# under the POSIX shell, with extra NAME=value inputs.
call() {
    local file="$1" fn="$2"; shift 2
    env -i "${FENCE[@]}" "$@" \
        "$POSIX_SH" -c '. "$1"; shift; "$@"' _ "$file" "$fn" 2>&1
}

# Run FN from the real script with positional ARGS (no env inputs).
call_args() {
    env -i "${FENCE[@]}" \
        "$POSIX_SH" -c '. "$1"; shift; "$@"' _ "$SCRIPT" "$@" 2>&1
}

# ------------------------------------------------------------ wd_decide table

NOW=1000000
# Every guard on its kill side; each row moves exactly one input.
decide() {
    local file="$1"; shift
    call "$file" wd_decide NOW=$NOW HEARTBEAT_AT=$((NOW - 61)) PREV_STALE=1 \
        UPTIME=130 PREV_CHECK_AT=$((NOW - 60)) INSTALLING_AT=$((NOW - 360)) "$@"
}

# Prints "label|want|got" rows for FILE.
decide_table() {
    local f="$1"
    echo "heartbeat 59 s old|ok|$(decide "$f" HEARTBEAT_AT=$((NOW - 59)))"
    echo "heartbeat 61 s old|kill|$(decide "$f" HEARTBEAT_AT=$((NOW - 61)))"
    echo "first stale check (PREV_STALE=0)|stale_once|$(decide "$f" PREV_STALE=0)"
    echo "second stale check (PREV_STALE=1)|kill|$(decide "$f" PREV_STALE=1)"
    echo "uptime 100 s|skip_launch|$(decide "$f" UPTIME=100)"
    echo "uptime 130 s|kill|$(decide "$f" UPTIME=130)"
    echo "previous check 60 s ago|kill|$(decide "$f" PREV_CHECK_AT=$((NOW - 60)))"
    echo "previous check 120 s ago (slept)|skip_sleep|$(decide "$f" PREV_CHECK_AT=$((NOW - 120)))"
    echo "installing marker 240 s old|skip_install|$(decide "$f" INSTALLING_AT=$((NOW - 240)))"
    echo "installing marker 360 s old|kill|$(decide "$f" INSTALLING_AT=$((NOW - 360)))"
    echo "no installing marker|kill|$(decide "$f" INSTALLING_AT=)"
    echo "first-ever check (no previous check)|stale_once|$(decide "$f" PREV_CHECK_AT= PREV_STALE=0)"
}

# Returns the number of failed rows; prints them only when asked.
run_table() {
    local f="$1" verbose="$2" bad=0 label want got
    while IFS='|' read -r label want got; do
        if [ "$got" != "$want" ]; then
            bad=$((bad + 1))
            [ "$verbose" = "1" ] && echo "FAIL: wd_decide $label — want '$want', got '$got'"
        fi
    done < <(decide_table "$f")
    return "$bad"
}

rows=$(decide_table "$SCRIPT" | wc -l | tr -d ' ')
run_table "$SCRIPT" 1
table_failures=$?
checks=$((checks + rows))
failures=$((failures + table_failures))

# The broken fixture kills on the first stale check. If the table cannot tell,
# the table is not testing the two-checks rule.
checks=$((checks + 1))
run_table "$BROKEN" 0
if [ "$?" -eq 0 ]; then
    echo "FAIL: the broken fixture ($BROKEN) passed every wd_decide assertion"
    failures=$((failures + 1))
fi

# --------------------------------------------------------- the helper tables

for d in ok skip_sleep skip_install kill; do
    check "wd_counts_as_stale $d" 0 "$(call_args wd_counts_as_stale "$d")"
done
for d in stale_once skip_launch; do
    check "wd_counts_as_stale $d" 1 "$(call_args wd_counts_as_stale "$d")"
done
check "etime mm:ss" 125 "$(call_args wd_etime_secs 02:05)"
check "etime hh:mm:ss" 3725 "$(call_args wd_etime_secs 01:02:05)"
check "etime dd-hh:mm:ss" 90125 "$(call_args wd_etime_secs 1-01:02:05)"

# --------------------------------------------------------------- integration

TMP=$(mktemp -d "${TMPDIR:-/tmp}/quip-wd-test.XXXXXX")
VICTIM=""
cleanup() {
    [ -n "$VICTIM" ] && kill -9 "$VICTIM" 2>/dev/null
    rm -rf "$TMP" "$FENCE_DIR"
}
trap cleanup EXIT

# A detached `sleep 300` stands in for Quip. Detached (not a job of this shell)
# so a dead victim is reaped at once and bash prints no "Killed: 9".
start_victim() { (sleep 300 >/dev/null 2>&1 & echo $!); }

# Sourcing alone must run nothing: no state, no log, no kill.
VICTIM=$(start_victim)
mkdir -p "$TMP/src-state" "$TMP/src-logs"
echo $(( $(date +%s) - 100 )) > "$TMP/src-state/heartbeat"
env QUIP_WD_SOURCE_ONLY=1 QUIP_WD_PID="$VICTIM" QUIP_WD_UPTIME=300 \
    QUIP_WD_STATE_DIR="$TMP/src-state" QUIP_WD_LOG_DIR="$TMP/src-logs" QUIP_WD_SAMPLE=/usr/bin/true \
    /bin/sh -c '. "$1"' _ "$SCRIPT"
kill -0 "$VICTIM" 2>/dev/null; check "sourced only: the process survives" 0 "$?"
check "sourced only: no watchdog.state written" no "$([ -e "$TMP/src-state/watchdog.state" ] && echo yes || echo no)"
check "sourced only: no watchdog.log written" no "$([ -e "$TMP/src-logs/watchdog.log" ] && echo yes || echo no)"

# A real process with a heartbeat 100 s old: alive after one check, gone after
# two. The age reads 101 s when a second ticks over between write and check.
mkdir -p "$TMP/state" "$TMP/logs"
echo $(( $(date +%s) - 100 )) > "$TMP/state/heartbeat"
run_watchdog() {
    env QUIP_WD_PID="$VICTIM" QUIP_WD_UPTIME=300 QUIP_WD_SAMPLE=/usr/bin/true \
        QUIP_WD_STATE_DIR="$TMP/state" QUIP_WD_LOG_DIR="$TMP/logs" /bin/sh "$SCRIPT"
}
run_watchdog
check "first run exits 0" 0 "$?"
kill -0 "$VICTIM" 2>/dev/null; check "after the first stale check the process is alive" 0 "$?"
check "first run logs one 'watching' line" 1 "$(grep -c "stale pid=$VICTIM heartbeat_age=10[01]s action=watching" "$TMP/logs/watchdog.log" 2>/dev/null)"
run_watchdog
check "second run exits 0" 0 "$?"
# kill -9 is asynchronous to the reaper; give it a moment.
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$VICTIM" 2>/dev/null || break; sleep 0.1; done
kill -0 "$VICTIM" 2>/dev/null; check "after the second stale check the process is gone" 1 "$?"
line=$(grep "action=killed" "$TMP/logs/watchdog.log" 2>/dev/null)
hang=$(printf '%s' "$line" | sed -n 's/.* sample=\(hang-[0-9TZ]*\.txt\)$/\1/p')
check "one kill line in watchdog.log" 1 "$(grep -c "hang pid=$VICTIM heartbeat_age=10[01]s action=killed sample=hang-" "$TMP/logs/watchdog.log" 2>/dev/null)"
check "the sample file named in the log exists" yes "$([ -n "$hang" ] && [ -f "$TMP/logs/$hang" ] && echo yes || echo no)"
VICTIM=""

# A Quip that writes no heartbeat (today's app) is never judged.
VICTIM=$(start_victim)
mkdir -p "$TMP/nohb-state" "$TMP/nohb-logs"
for _ in 1 2 3; do
    env QUIP_WD_PID="$VICTIM" QUIP_WD_UPTIME=300 QUIP_WD_SAMPLE=/usr/bin/true \
        QUIP_WD_STATE_DIR="$TMP/nohb-state" QUIP_WD_LOG_DIR="$TMP/nohb-logs" /bin/sh "$SCRIPT"
done
kill -0 "$VICTIM" 2>/dev/null; check "no heartbeat file: the process survives three checks" 0 "$?"

echo "watchdog tests: $checks checks, $failures failures"
[ "$failures" -eq 0 ]
