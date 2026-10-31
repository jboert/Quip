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
       QUIP_WD_STATE_DIR="$FENCE_DIR" QUIP_WD_LOG_DIR="$FENCE_DIR" QUIP_WD_SAMPLE=/usr/bin/true
       QUIP_WD_LAUNCHCTL=/usr/bin/true QUIP_WD_AGENT_PLIST="$FENCE_DIR/none.plist" QUIP_WD_FREE_MB=100000)

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

# Runs TABLE (a function printing "label|want|got" rows) against FILE.
# Returns the number of failed rows; prints them only when asked.
run_table() {
    local table="$1" f="$2" verbose="$3" bad=0 label want got
    while IFS='|' read -r label want got; do
        if [ "$got" != "$want" ]; then
            bad=$((bad + 1))
            [ "$verbose" = "1" ] && echo "FAIL: $table $label — want '$want', got '$got'"
        fi
    done < <("$table" "$f")
    return "$bad"
}

rows=$(decide_table "$SCRIPT" | wc -l | tr -d ' ')
run_table decide_table "$SCRIPT" 1
table_failures=$?
checks=$((checks + rows))
failures=$((failures + table_failures))

# The broken fixture kills on the first stale check. If the table cannot tell,
# the table is not testing the two-checks rule.
checks=$((checks + 1))
run_table decide_table "$BROKEN" 0
if [ "$?" -eq 0 ]; then
    echo "FAIL: the broken fixture ($BROKEN) passed every wd_decide assertion"
    failures=$((failures + 1))
fi

# ------------------------------------------------------- wd_loop_decide table

# Not stopped, plenty of disk, no restarts: each row moves what it names.
loop() {
    local file="$1"; shift
    call "$file" wd_loop_decide NOW=$NOW RESTART_TIMES= STOPPED_AT= RETRIED=0 FREE_MB=100000 "$@"
}

three_recent="$((NOW - 500)) $((NOW - 300)) $((NOW - 100))"
loop_table() {
    local f="$1"
    echo "no restarts|ok|$(loop "$f")"
    echo "2 restarts in 10 min|ok|$(loop "$f" RESTART_TIMES="$((NOW - 300)) $((NOW - 100))")"
    echo "3 restarts in 10 min|stop|$(loop "$f" RESTART_TIMES="$three_recent")"
    echo "3 restarts spread over 11 min|ok|$(loop "$f" RESTART_TIMES="$((NOW - 660)) $((NOW - 330)) $NOW")"
    echo "3 recent restarts among older ones|stop|$(loop "$f" RESTART_TIMES="$((NOW - 5000)) $((NOW - 4000)) $three_recent")"
    echo "stopped 1799 s ago|stay_stopped|$(loop "$f" STOPPED_AT=$((NOW - 1799)))"
    echo "stopped 1801 s ago, not retried|retry|$(loop "$f" STOPPED_AT=$((NOW - 1801)))"
    echo "second stop after the retry (3 more restarts)|stay_stopped|$(loop "$f" STOPPED_AT=$((NOW - 2400)) RETRIED=1 RESTART_TIMES="$three_recent")"
    echo "stopped and retried long ago|stay_stopped|$(loop "$f" STOPPED_AT=$((NOW - 99999)) RETRIED=1)"
    echo "400 MB free|disk_full|$(loop "$f" FREE_MB=400)"
    echo "1000 MB free|ok|$(loop "$f" FREE_MB=1000)"
    echo "400 MB free beats a crash loop|disk_full|$(loop "$f" FREE_MB=400 RESTART_TIMES="$three_recent")"
    echo "400 MB free beats a due retry|disk_full|$(loop "$f" FREE_MB=400 STOPPED_AT=$((NOW - 1801)))"
    echo "3 recent restarts, owner opened Quip after them|ok|$(loop "$f" RESTART_TIMES="$three_recent" SINCE=$((NOW - 50)))"
    echo "3 recent restarts, owner opened Quip before them|stop|$(loop "$f" RESTART_TIMES="$three_recent" SINCE=$((NOW - 550)))"
}

rows=$(loop_table "$SCRIPT" | wc -l | tr -d ' ')
run_table loop_table "$SCRIPT" 1
table_failures=$?
checks=$((checks + rows))
failures=$((failures + table_failures))

# The broken fixture stops at 4 restarts. If the loop table cannot tell, it is
# not testing the 3-in-10-min rule.
checks=$((checks + 1))
run_table loop_table "$BROKEN" 0
if [ "$?" -eq 0 ]; then
    echo "FAIL: the broken fixture ($BROKEN) passed every wd_loop_decide assertion"
    failures=$((failures + 1))
fi

# ---------------------------------------------------- wd_restart_reason table

# A pid change with nothing to explain it is a crash; each row adds one reason
# it is not.
reason() {
    call "$SCRIPT" wd_restart_reason NOW=$NOW PREV_CHECK_AT=$((NOW - 30)) PREV_PID=100 \
        INSTALLING_AT= MANUAL_AT= BOOT_AT=$((NOW - 99999)) EXIT_PID= "$@"
}
check "reason: nothing to explain it" crash "$(reason)"
check "reason: install 4 min ago" none "$(reason INSTALLING_AT=$((NOW - 240)))"
check "reason: install 6 min ago" crash "$(reason INSTALLING_AT=$((NOW - 360)))"
check "reason: owner opened Quip 1 min ago" none "$(reason MANUAL_AT=$((NOW - 60)))"
check "reason: owner opened Quip 6 min ago" crash "$(reason MANUAL_AT=$((NOW - 360)))"
check "reason: the Mac booted since the last check" none "$(reason BOOT_AT=$((NOW - 10)))"
check "reason: booted before the last check" crash "$(reason BOOT_AT=$((NOW - 40)))"
check "reason: the old pid quit through the app" quit "$(reason EXIT_PID=100)"
check "reason: another pid quit through the app" crash "$(reason EXIT_PID=99)"
check "reason: a reboot beats a quit" none "$(reason EXIT_PID=100 BOOT_AT=$((NOW - 10)))"

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

# Every main-path run gets a stub launchctl that records its arguments, a
# plist under $TMP and a roomy disk, so no run can touch the owner's real
# crash agent.
STUB="$TMP/launchctl-stub"
LAUNCHCTL_CALLS="$TMP/launchctl-calls"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$LAUNCHCTL_CALLS" > "$STUB"
chmod +x "$STUB"
PLIST="$TMP/com.quip.QuipMac.crash-recovery.plist"
: > "$PLIST"
SAFE=(QUIP_WD_LAUNCHCTL="$STUB" QUIP_WD_AGENT_PLIST="$PLIST" QUIP_WD_FREE_MB=100000)

# A detached `sleep 300` stands in for Quip. Detached (not a job of this shell)
# so a dead victim is reaped at once and bash prints no "Killed: 9".
start_victim() { (sleep 300 >/dev/null 2>&1 & echo $!); }

# Sourcing alone must run nothing: no state, no log, no kill.
VICTIM=$(start_victim)
mkdir -p "$TMP/src-state" "$TMP/src-logs"
echo $(( $(date +%s) - 100 )) > "$TMP/src-state/heartbeat"
env QUIP_WD_SOURCE_ONLY=1 QUIP_WD_PID="$VICTIM" QUIP_WD_UPTIME=300 "${SAFE[@]}" \
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
    env QUIP_WD_PID="$VICTIM" QUIP_WD_UPTIME=300 QUIP_WD_SAMPLE=/usr/bin/true "${SAFE[@]}" \
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
check "the kill is recorded in restarts.json as a hang" 1 "$(grep -c '"reason": "hang"' "$TMP/state/restarts.json" 2>/dev/null)"
VICTIM=""

# A Quip that writes no heartbeat (today's app) is never judged.
VICTIM=$(start_victim)
mkdir -p "$TMP/nohb-state" "$TMP/nohb-logs"
for _ in 1 2 3; do
    env QUIP_WD_PID="$VICTIM" QUIP_WD_UPTIME=300 QUIP_WD_SAMPLE=/usr/bin/true "${SAFE[@]}" \
        QUIP_WD_STATE_DIR="$TMP/nohb-state" QUIP_WD_LOG_DIR="$TMP/nohb-logs" /bin/sh "$SCRIPT"
done
kill -0 "$VICTIM" 2>/dev/null; check "no heartbeat file: the process survives three checks" 0 "$?"

# ---------------------------------------------- crash loop, retry, full disk

UID_NOW=$(id -u)
kill -9 "$VICTIM" 2>/dev/null
VICTIM=$(start_victim)
VICTIM2=$(start_victim)
cleanup_loop() { kill -9 "$VICTIM2" 2>/dev/null; cleanup; }
trap cleanup_loop EXIT
mkdir -p "$TMP/loop-state" "$TMP/loop-logs"
: > "$LAUNCHCTL_CALLS"
LOOP_LOG="$TMP/loop-logs/watchdog.log"
LOOP_MARKER="$TMP/loop-state/stoppedForCrashLoop"
RESTARTS="$TMP/loop-state/restarts.json"
# run_loop PID: one watchdog check that sees Quip as PID.
run_loop() {
    env QUIP_WD_PID="$1" QUIP_WD_UPTIME=300 QUIP_WD_SAMPLE=/usr/bin/true "${SAFE[@]}" \
        QUIP_WD_STATE_DIR="$TMP/loop-state" QUIP_WD_LOG_DIR="$TMP/loop-logs" /bin/sh "$SCRIPT"
}
calls() { grep -c "$1" "$LAUNCHCTL_CALLS" 2>/dev/null; }
call_count() { wc -l < "$LAUNCHCTL_CALLS" | tr -d ' '; }
T=$(date +%s)
printf '[\n  {"at": %s, "reason": "crash"},\n  {"at": %s, "reason": "crash"}\n]\n' $((T - 200)) $((T - 100)) > "$RESTARTS"

run_loop "$VICTIM"
check "2 restarts on record: no launchctl call" 0 "$(call_count)"
check "2 restarts on record: no marker" no "$([ -e "$LOOP_MARKER" ] && echo yes || echo no)"

# An install relaunches Quip with a new pid, and is not a crash.
date +%s > "$TMP/loop-state/installing"
run_loop "$VICTIM2"
check "a pid change during an install is not a restart" 2 "$(grep -c '"at":' "$RESTARTS")"
check "a pid change during an install: no launchctl call" 0 "$(call_count)"
rm -f "$TMP/loop-state/installing"

# The third restart: a new pid outside an install.
run_loop "$VICTIM"
check "the new pid is recorded as a crash" 3 "$(grep -c '"reason": "crash"' "$RESTARTS")"
check "restarts.json is one JSON array of {at, reason}" ok "$(python3 -I -c '
import json, sys
a = json.load(open(sys.argv[1]))
print("ok" if isinstance(a, list) and all(sorted(e) == ["at", "reason"] for e in a) else "bad")' "$RESTARTS" 2>&1)"
check "3 restarts in 10 min: bootout of the crash agent" 1 "$(calls "^bootout gui/$UID_NOW/com.quip.QuipMac.crash-recovery$")"
check "3 restarts in 10 min: marker stoppedForCrashLoop" yes "$([ -f "$LOOP_MARKER" ] && echo yes || echo no)"
stop_line=$(grep 'crash_loop restarts=3 window=10m action=stopped retry_at=' "$LOOP_LOG")
retry_at=${stop_line##*retry_at=}
check "3 restarts in 10 min: one stop line" 1 "$(printf '%s\n' "$stop_line" | grep -c .)"
check "the stop line's retry_at is 30 min on" yes "$([ "$retry_at" -ge $((T + 1800)) ] && [ "$retry_at" -le $((T + 1805)) ] && echo yes || echo no)"

run_loop "$VICTIM"
check "stopped under 30 min ago: no bootstrap" 0 "$(calls '^bootstrap')"

# 30 min later (the marker's time moved back): exactly one retry.
printf 'stopped_at=%s\n' $(( $(date +%s) - 1801 )) > "$LOOP_MARKER"
run_loop "$VICTIM"
check "after 30 min: bootstrap with the agent plist" 1 "$(calls "^bootstrap gui/$UID_NOW $PLIST$")"
check "after 30 min: one retry line" 1 "$(grep -c 'crash_loop action=retry$' "$LOOP_LOG")"
run_loop "$VICTIM"
check "only one retry" 1 "$(calls '^bootstrap')"

# A crash after the retry stops it until the owner opens Quip. The retry is
# aged 10 s: times are whole seconds, and a real crash after a retry is at
# least launchd's 30 s throttle later, never in the same second.
printf 'stopped_at=%s\nretried_at=%s\n' $(( $(date +%s) - 1811 )) $(( $(date +%s) - 10 )) > "$LOOP_MARKER"
run_loop "$VICTIM2"
check "a crash after the retry: a second bootout" 2 "$(calls '^bootout')"
check "a crash after the retry: one stopped_again line" 1 "$(grep -c 'crash_loop action=stopped_again' "$LOOP_LOG")"
run_loop "$VICTIM"
check "stopped again: no further launchctl calls" 3 "$(call_count)"

# A full disk: no restart, one line and one bootout per episode, then resume.
mkdir -p "$TMP/disk-state" "$TMP/disk-logs"
: > "$LAUNCHCTL_CALLS"
run_disk() {
    env QUIP_WD_PID="$VICTIM" QUIP_WD_UPTIME=300 QUIP_WD_SAMPLE=/usr/bin/true "${SAFE[@]}" \
        QUIP_WD_STATE_DIR="$TMP/disk-state" QUIP_WD_LOG_DIR="$TMP/disk-logs" QUIP_WD_FREE_MB="$1" /bin/sh "$SCRIPT"
}
run_disk 400
run_disk 400
check "400 MB free: one disk_full line" 1 "$(grep -c 'disk_full free_mb=400 action=no_restart$' "$TMP/disk-logs/watchdog.log")"
check "400 MB free: one bootout" 1 "$(calls "^bootout gui/$UID_NOW/com.quip.QuipMac.crash-recovery$")"
run_disk 1000
check "space back: bootstrap" 1 "$(calls "^bootstrap gui/$UID_NOW $PLIST$")"
check "space back: one resumed line" 1 "$(grep -c 'disk_full free_mb=1000 action=resumed$' "$TMP/disk-logs/watchdog.log")"

# The agent is opt-in: with no plist installed, a retry never installs it.
mkdir -p "$TMP/noagent-state" "$TMP/noagent-logs"
: > "$LAUNCHCTL_CALLS"
printf 'stopped_at=%s\n' $(( $(date +%s) - 1801 )) > "$TMP/noagent-state/stoppedForCrashLoop"
env QUIP_WD_PID="$VICTIM" QUIP_WD_UPTIME=300 QUIP_WD_SAMPLE=/usr/bin/true "${SAFE[@]}" \
    QUIP_WD_AGENT_PLIST="$TMP/absent.plist" \
    QUIP_WD_STATE_DIR="$TMP/noagent-state" QUIP_WD_LOG_DIR="$TMP/noagent-logs" /bin/sh "$SCRIPT"
check "no agent plist: the retry bootstraps nothing" 0 "$(calls '^bootstrap')"

# launchd throttles a relaunch by 30 s, so a check often lands while Quip is
# down. The pid before the gap is remembered and the new one still counts.
# The down check runs with QUIP_WD_PID unset and a stub pgrep that finds
# nothing, so it can never see the owner's real Quip.
mkdir -p "$TMP/gap-state" "$TMP/gap-logs" "$TMP/nopgrep"
printf '#!/bin/sh\nexit 1\n' > "$TMP/nopgrep/pgrep"
chmod +x "$TMP/nopgrep/pgrep"
run_gap() {
    env "$@" QUIP_WD_UPTIME=300 QUIP_WD_SAMPLE=/usr/bin/true "${SAFE[@]}" \
        QUIP_WD_STATE_DIR="$TMP/gap-state" QUIP_WD_LOG_DIR="$TMP/gap-logs" /bin/sh "$SCRIPT"
}
run_gap QUIP_WD_PID="$VICTIM"
run_gap -u QUIP_WD_PID PATH="$TMP/nopgrep:$PATH"
run_gap QUIP_WD_PID="$VICTIM2"
check "a new pid after a check with Quip down is a crash" 1 "$(grep -c '"reason": "crash"' "$TMP/gap-state/restarts.json" 2>/dev/null)"

# The owner opening Quip, and a quit through the app, are told apart from a
# crash on the main path too.
mkdir -p "$TMP/why-state" "$TMP/why-logs"
run_why() {
    env QUIP_WD_PID="$1" QUIP_WD_UPTIME=300 QUIP_WD_SAMPLE=/usr/bin/true "${SAFE[@]}" \
        QUIP_WD_STATE_DIR="$TMP/why-state" QUIP_WD_LOG_DIR="$TMP/why-logs" /bin/sh "$SCRIPT"
}
run_why "$VICTIM"
date +%s > "$TMP/why-state/manual-launch"
run_why "$VICTIM2"
check "a pid change right after the owner opened Quip is not a restart" 0 \
    "$(grep -c '"at":' "$TMP/why-state/restarts.json" 2>/dev/null || echo 0)"
rm -f "$TMP/why-state/manual-launch"
printf 'pid=%s\n' "$VICTIM2" > "$TMP/why-state/exit"
run_why "$VICTIM"
check "a pid change after the old Quip quit is recorded as quit" 1 \
    "$(grep -c '"reason": "quit"' "$TMP/why-state/restarts.json" 2>/dev/null)"
env QUIP_WD_BOOT_AT=$(( $(date +%s) + 5 )) QUIP_WD_PID="$VICTIM2" QUIP_WD_UPTIME=300 QUIP_WD_SAMPLE=/usr/bin/true \
    "${SAFE[@]}" QUIP_WD_STATE_DIR="$TMP/why-state" QUIP_WD_LOG_DIR="$TMP/why-logs" /bin/sh "$SCRIPT"
check "a pid change across a reboot is not a restart" 1 \
    "$(grep -c '"at":' "$TMP/why-state/restarts.json" 2>/dev/null)"

echo "watchdog tests: $checks checks, $failures failures"
[ "$failures" -eq 0 ]
