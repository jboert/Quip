#!/bin/sh
# Q-90 — the Quip hang watchdog. launchd runs it every 30 s
# (com.quip.QuipMac.watchdog, `/bin/sh` on this file: no TCC, no new binary).
#
# A hung Quip is sampled and `kill -9`ed (Quip traps SIGTERM) so the crash
# agent relaunches it. Sleep, a slow launch and an install must never look
# like a hang, so a kill needs ALL of:
#   - the heartbeat is older than 60 s on two consecutive checks;
#   - Quip has been up more than 120 s;
#   - this watchdog's previous check was less than 90 s ago (a longer gap
#     means the Mac slept: skip one round);
#   - no `installing` marker younger than 5 min.
# These are constants on purpose, tuned from watchdog.log, not settings.
#
# POSIX sh and stock macOS tools only. Sourcing with QUIP_WD_SOURCE_ONLY=1
# defines the functions and runs nothing (tools/run-watchdog-tests.sh).
#
# Environment (all optional; the defaults are the real paths):
#   QUIP_WD_STATE_DIR  heartbeat, installing, watchdog.state
#                      (default ~/Library/Application Support/Quip)
#   QUIP_WD_LOG_DIR    watchdog.log, hang-<time>.txt (default ~/Library/Logs/Quip)
#   QUIP_WD_PID        the Quip pid (default: `pgrep -x Quip`, simulator copies skipped)
#   QUIP_WD_SAMPLE     the sampler (default `sample`)
#   QUIP_WD_UPTIME     Quip's uptime in seconds, for tests (default: from `ps`)

WD_HANG_SECS=60
WD_MIN_UPTIME_SECS=120
WD_MAX_CHECK_GAP_SECS=90
WD_INSTALL_GRACE_SECS=300

# Pure. Reads NOW, HEARTBEAT_AT, PREV_STALE (0/1), UPTIME, PREV_CHECK_AT and
# INSTALLING_AT (empty = no marker) and prints exactly one of
# ok | stale_once | skip_sleep | skip_launch | skip_install | kill.
# An empty PREV_CHECK_AT is a first-ever check: there is no gap to judge, and
# the two-consecutive-checks rule still stands between it and a kill.
wd_decide() {
    if [ $((NOW - HEARTBEAT_AT)) -le "$WD_HANG_SECS" ]; then
        echo ok; return
    fi
    if [ -n "${INSTALLING_AT:-}" ] && [ $((NOW - INSTALLING_AT)) -lt "$WD_INSTALL_GRACE_SECS" ]; then
        echo skip_install; return
    fi
    if [ -n "${PREV_CHECK_AT:-}" ] && [ $((NOW - PREV_CHECK_AT)) -ge "$WD_MAX_CHECK_GAP_SECS" ]; then
        echo skip_sleep; return
    fi
    if [ "${PREV_STALE:-0}" != 1 ]; then
        echo stale_once; return
    fi
    if [ "$UPTIME" -le "$WD_MIN_UPTIME_SECS" ]; then
        echo skip_launch; return
    fi
    echo kill
}

# Whether a decision leaves this check counted as stale for the next one.
# A skipped sleep or install round does not: after either, two fresh stale
# checks are needed again.
wd_counts_as_stale() {
    case "$1" in
        stale_once|skip_launch) echo 1 ;;
        *) echo 0 ;;
    esac
}

# `ps -o etime=` ([[dd-]hh:]mm:ss) to seconds.
wd_etime_secs() {
    echo "$1" | awk '{
        s = $1; d = 0
        if (index(s, "-")) { split(s, a, "-"); d = a[1]; s = a[2] }
        n = split(s, p, ":"); t = 0
        for (i = 1; i <= n; i++) t = t * 60 + p[i]
        print d * 86400 + t
    }'
}

# A file's epoch: its contents when they are a bare number, else its mtime.
wd_read_epoch() {
    [ -f "$1" ] || return 0
    v=$(tr -d ' \n' < "$1")
    case "$v" in
        ''|*[!0-9]*) stat -f %m "$1" ;;
        *) echo "$v" ;;
    esac
}

wd_find_pid() {
    if [ -n "${QUIP_WD_PID:-}" ]; then
        echo "$QUIP_WD_PID"; return
    fi
    for p in $(pgrep -x Quip); do
        # `pgrep -x Quip` also matches the iOS app in a simulator.
        case "$(ps -o command= -p "$p")" in
            *CoreSimulator*) ;;
            *) echo "$p"; return ;;
        esac
    done
}

wd_log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$WD_LOG_DIR/watchdog.log"
}

wd_main() {
    WD_STATE_DIR=${QUIP_WD_STATE_DIR:-"$HOME/Library/Application Support/Quip"}
    WD_LOG_DIR=${QUIP_WD_LOG_DIR:-"$HOME/Library/Logs/Quip"}
    mkdir -p "$WD_STATE_DIR" "$WD_LOG_DIR"
    state="$WD_STATE_DIR/watchdog.state"

    NOW=$(date +%s)
    PREV_CHECK_AT=""; PREV_STALE=0
    if [ -f "$state" ]; then
        PREV_CHECK_AT=$(sed -n 's/^check_at=//p' "$state")
        PREV_STALE=$(sed -n 's/^stale=//p' "$state")
    fi

    pid=$(wd_find_pid)
    HEARTBEAT_AT=$(wd_read_epoch "$WD_STATE_DIR/heartbeat")
    # No Quip, or a Quip that does not write heartbeats: nothing to judge.
    # A crash is the crash agent's job, not this one's.
    if [ -z "$pid" ] || [ -z "$HEARTBEAT_AT" ]; then
        printf 'check_at=%s\nstale=0\n' "$NOW" > "$state"
        return 0
    fi

    if [ -n "${QUIP_WD_UPTIME:-}" ]; then
        UPTIME=$QUIP_WD_UPTIME
    else
        UPTIME=$(wd_etime_secs "$(ps -o etime= -p "$pid" | tr -d ' ')")
    fi
    INSTALLING_AT=$(wd_read_epoch "$WD_STATE_DIR/installing")
    age=$((NOW - HEARTBEAT_AT))

    decision=$(wd_decide)
    printf 'check_at=%s\nstale=%s\n' "$NOW" "$(wd_counts_as_stale "$decision")" > "$state"

    case "$decision" in
        kill)
            hang="hang-$(date -u +%Y%m%dT%H%M%SZ).txt"
            ${QUIP_WD_SAMPLE:-sample} "$pid" 3 > "$WD_LOG_DIR/$hang" 2>&1
            kill -9 "$pid"
            wd_log "hang pid=$pid heartbeat_age=${age}s action=killed sample=$hang"
            ;;
        stale_once) wd_log "stale pid=$pid heartbeat_age=${age}s action=watching" ;;
        skip_sleep) wd_log "stale pid=$pid heartbeat_age=${age}s action=skipped reason=sleep" ;;
        skip_launch) wd_log "stale pid=$pid heartbeat_age=${age}s action=skipped reason=launch uptime=${UPTIME}s" ;;
        skip_install) wd_log "stale pid=$pid heartbeat_age=${age}s action=skipped reason=installing" ;;
    esac
}

if [ "${QUIP_WD_SOURCE_ONLY:-0}" != 1 ]; then
    wd_main
fi
