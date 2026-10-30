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
#
# It also stops a crash loop. Every restart (a hang kill, or a new Quip pid
# after a known one outside an install) goes into restarts.json. Three within
# 10 min boot the crash agent out and leave the marker stoppedForCrashLoop;
# 30 min later it is bootstrapped once more, and a crash after that stops it
# until the owner opens Quip. A disk with less than 500 MB free boots the
# agent out too (a restart would only crash again) and resumes when space is
# back.
# These are constants on purpose, tuned from watchdog.log, not settings.
#
# POSIX sh and stock macOS tools only. Sourcing with QUIP_WD_SOURCE_ONLY=1
# defines the functions and runs nothing (tools/run-watchdog-tests.sh).
#
# Environment (all optional; the defaults are the real paths):
#   QUIP_WD_STATE_DIR  heartbeat, installing, watchdog.state, restarts.json,
#                      stoppedForCrashLoop, stoppedForDiskFull
#                      (default ~/Library/Application Support/Quip)
#   QUIP_WD_LOG_DIR    watchdog.log, hang-<time>.txt (default ~/Library/Logs/Quip)
#   QUIP_WD_PID        the Quip pid (default: `pgrep -x Quip`, simulator copies skipped)
#   QUIP_WD_SAMPLE     the sampler (default `sample`)
#   QUIP_WD_UPTIME     Quip's uptime in seconds, for tests (default: from `ps`)
#   QUIP_WD_LAUNCHCTL  launchctl (default /bin/launchctl)
#   QUIP_WD_AGENT_PLIST the crash agent's plist
#                      (default ~/Library/LaunchAgents/com.quip.QuipMac.crash-recovery.plist)
#   QUIP_WD_FREE_MB    free MB on the home volume, for tests (default: from `df`)

WD_HANG_SECS=60
WD_MIN_UPTIME_SECS=120
WD_MAX_CHECK_GAP_SECS=90
WD_INSTALL_GRACE_SECS=300
WD_LOOP_RESTARTS=3
WD_LOOP_WINDOW_SECS=600
WD_RETRY_AFTER_SECS=1800
WD_MIN_FREE_MB=500
WD_KEEP_RESTARTS=10
WD_AGENT_LABEL=com.quip.QuipMac.crash-recovery

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

# Pure. Reads NOW, RESTART_TIMES (space-separated epochs), STOPPED_AT (empty =
# not stopped), RETRIED (0/1) and FREE_MB, and prints exactly one of
# ok | stop | retry | stay_stopped | disk_full. A full disk wins over
# everything: a restart would only crash again.
wd_loop_decide() {
    if [ "${FREE_MB:-$WD_MIN_FREE_MB}" -lt "$WD_MIN_FREE_MB" ]; then
        echo disk_full; return
    fi
    if [ -n "${STOPPED_AT:-}" ]; then
        if [ "${RETRIED:-0}" != 1 ] && [ $((NOW - STOPPED_AT)) -ge "$WD_RETRY_AFTER_SECS" ]; then
            echo retry
        else
            echo stay_stopped
        fi
        return
    fi
    if [ "$(wd_restarts_in_window)" -ge "$WD_LOOP_RESTARTS" ]; then
        echo stop
    else
        echo ok
    fi
}

# How many of RESTART_TIMES fall within the loop window before NOW.
wd_restarts_in_window() {
    n=0
    for t in ${RESTART_TIMES:-}; do
        [ $((NOW - t)) -le "$WD_LOOP_WINDOW_SECS" ] && n=$((n + 1))
    done
    echo "$n"
}

# The `at` epochs in a restarts.json, space-separated. A missing or
# malformed file reads as no restarts.
wd_restart_times() {
    [ -f "$1" ] || return 0
    grep -o '"at": *[0-9][0-9]*' "$1" | tr -dc '0-9\n' | tr '\n' ' ' | sed 's/ *$//'
}

# Appends {at, reason} to a restarts.json, keeping the newest
# $WD_KEEP_RESTARTS entries. Entries that do not parse are dropped.
wd_record_restart() {
    file=$1 at=$2 reason=$3
    {
        [ -f "$file" ] && grep -o '{[^}]*"at": *[0-9][0-9]*[^}]*}' "$file"
        printf '{"at": %s, "reason": "%s"}\n' "$at" "$reason"
    } | tail -n "$WD_KEEP_RESTARTS" | awk '
        BEGIN { print "[" }
        { if (NR > 1) print prev ","; prev = "  " $0 }
        END { if (NR > 0) print prev; print "]" }' > "$file.tmp" && mv "$file.tmp" "$file"
}

wd_launchctl() {
    ${QUIP_WD_LAUNCHCTL:-/bin/launchctl} "$@" > /dev/null 2>&1
}

wd_bootout_agent() {
    wd_launchctl bootout "gui/$(id -u)/$WD_AGENT_LABEL"
}

# Re-bootstraps the crash agent, but only if the owner installed it: the agent
# is opt-in and the watchdog must never install it on its own.
wd_bootstrap_agent() {
    [ -f "$WD_AGENT_PLIST" ] || return 0
    wd_launchctl bootstrap "gui/$(id -u)" "$WD_AGENT_PLIST"
}

wd_log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$WD_LOG_DIR/watchdog.log"
}

# The hang check. Sets $last_pid empty after a kill, so the relaunch that
# follows is not counted a second time as a crash.
wd_hang_step() {
    HEARTBEAT_AT=$(wd_read_epoch "$WD_STATE_DIR/heartbeat")
    # No Quip, or a Quip that does not write heartbeats: nothing to judge.
    if [ -z "$pid" ] || [ -z "$HEARTBEAT_AT" ]; then
        stale=0
        return 0
    fi

    if [ -n "${QUIP_WD_UPTIME:-}" ]; then
        UPTIME=$QUIP_WD_UPTIME
    else
        UPTIME=$(wd_etime_secs "$(ps -o etime= -p "$pid" | tr -d ' ')")
    fi
    age=$((NOW - HEARTBEAT_AT))

    decision=$(wd_decide)
    stale=$(wd_counts_as_stale "$decision")

    case "$decision" in
        kill)
            hang="hang-$(date -u +%Y%m%dT%H%M%SZ).txt"
            ${QUIP_WD_SAMPLE:-sample} "$pid" 3 > "$WD_LOG_DIR/$hang" 2>&1
            kill -9 "$pid"
            wd_log "hang pid=$pid heartbeat_age=${age}s action=killed sample=$hang"
            wd_record_restart "$restarts" "$NOW" hang
            last_pid=""
            ;;
        stale_once) wd_log "stale pid=$pid heartbeat_age=${age}s action=watching" ;;
        skip_sleep) wd_log "stale pid=$pid heartbeat_age=${age}s action=skipped reason=sleep" ;;
        skip_launch) wd_log "stale pid=$pid heartbeat_age=${age}s action=skipped reason=launch uptime=${UPTIME}s" ;;
        skip_install) wd_log "stale pid=$pid heartbeat_age=${age}s action=skipped reason=installing" ;;
    esac
}

# The crash-loop and disk check. Runs whether or not Quip is up: a Quip that
# dies before its own code runs is exactly the case it is for.
wd_loop_step() {
    loop_marker="$WD_STATE_DIR/stoppedForCrashLoop"
    disk_marker="$WD_STATE_DIR/stoppedForDiskFull"

    if [ -n "${QUIP_WD_FREE_MB:-}" ]; then
        FREE_MB=$QUIP_WD_FREE_MB
    else
        FREE_MB=$(df -m "$HOME" | awk 'NR == 2 { print $4 }')
    fi
    STOPPED_AT=""; RETRIED=0; retried_at=""; stopped_again=""
    if [ -f "$loop_marker" ]; then
        STOPPED_AT=$(sed -n 's/^stopped_at=//p' "$loop_marker")
        retried_at=$(sed -n 's/^retried_at=//p' "$loop_marker")
        stopped_again=$(sed -n 's/^stopped_again=//p' "$loop_marker")
        # A marker with no readable time still means stopped: stay down.
        [ -n "$STOPPED_AT" ] || STOPPED_AT=$NOW
        [ -n "$retried_at" ] && RETRIED=1
    fi
    RESTART_TIMES=$(wd_restart_times "$restarts")

    loop=$(wd_loop_decide)

    if [ "$loop" = disk_full ]; then
        # One line and one bootout per full-disk episode, not every 30 s.
        if [ ! -f "$disk_marker" ]; then
            wd_log "disk_full free_mb=$FREE_MB action=no_restart"
            wd_bootout_agent
            echo "$NOW" > "$disk_marker"
        fi
        last_pid=""
        return 0
    fi
    # Space is back: resume by itself, unless a crash loop also holds it down.
    if [ -f "$disk_marker" ]; then
        rm -f "$disk_marker"
        wd_log "disk_full free_mb=$FREE_MB action=resumed"
        [ -z "${STOPPED_AT:-}" ] && wd_bootstrap_agent
    fi

    case "$loop" in
        stop)
            wd_bootout_agent
            printf 'stopped_at=%s\n' "$NOW" > "$loop_marker"
            wd_log "crash_loop restarts=$(wd_restarts_in_window) window=$((WD_LOOP_WINDOW_SECS / 60))m action=stopped retry_at=$((NOW + WD_RETRY_AFTER_SECS))"
            last_pid=""
            ;;
        retry)
            printf 'retried_at=%s\n' "$NOW" >> "$loop_marker"
            wd_log "crash_loop action=retry"
            wd_bootstrap_agent
            ;;
        stay_stopped)
            # The retry was the one more try: a crash after it stops Quip
            # until the owner opens it again.
            newest=$(echo "$RESTART_TIMES" | tr ' ' '\n' | sort -n | tail -n 1)
            if [ "$RETRIED" = 1 ] && [ -z "$stopped_again" ] && [ -n "$newest" ] && [ "$newest" -gt "$retried_at" ]; then
                wd_bootout_agent
                printf 'stopped_again=%s\n' "$NOW" >> "$loop_marker"
                wd_log "crash_loop action=stopped_again reason=crashed_after_retry"
                last_pid=""
            fi
            ;;
    esac
}

wd_main() {
    WD_STATE_DIR=${QUIP_WD_STATE_DIR:-"$HOME/Library/Application Support/Quip"}
    WD_LOG_DIR=${QUIP_WD_LOG_DIR:-"$HOME/Library/Logs/Quip"}
    WD_AGENT_PLIST=${QUIP_WD_AGENT_PLIST:-"$HOME/Library/LaunchAgents/$WD_AGENT_LABEL.plist"}
    mkdir -p "$WD_STATE_DIR" "$WD_LOG_DIR"
    state="$WD_STATE_DIR/watchdog.state"
    restarts="$WD_STATE_DIR/restarts.json"

    NOW=$(date +%s)
    PREV_CHECK_AT=""; PREV_STALE=0; PREV_PID=""
    if [ -f "$state" ]; then
        PREV_CHECK_AT=$(sed -n 's/^check_at=//p' "$state")
        PREV_STALE=$(sed -n 's/^stale=//p' "$state")
        PREV_PID=$(sed -n 's/^pid=//p' "$state")
    fi

    pid=$(wd_find_pid)
    INSTALLING_AT=$(wd_read_epoch "$WD_STATE_DIR/installing")
    # A new pid after a known one is a restart: the crash agent relaunched
    # Quip. An install relaunches it too, and is not a crash.
    if [ -n "$pid" ] && [ -n "$PREV_PID" ] && [ "$pid" != "$PREV_PID" ]; then
        if [ -z "$INSTALLING_AT" ] || [ $((NOW - INSTALLING_AT)) -ge "$WD_INSTALL_GRACE_SECS" ]; then
            wd_record_restart "$restarts" "$NOW" crash
        fi
    fi
    # Remember the last pid seen, across checks where Quip is briefly down.
    last_pid=${pid:-$PREV_PID}

    wd_hang_step
    wd_loop_step

    printf 'check_at=%s\nstale=%s\npid=%s\n' "$NOW" "$stale" "$last_pid" > "$state"
}

if [ "${QUIP_WD_SOURCE_ONLY:-0}" != 1 ]; then
    wd_main
fi
