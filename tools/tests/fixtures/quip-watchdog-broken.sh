# Deliberately broken wd_decide for tools/run-watchdog-tests.sh: it kills on
# the FIRST stale check, ignoring PREV_STALE. The runner fails if this passes
# every assertion, which would mean the table cannot catch that bug.
wd_decide() {
    if [ $((NOW - HEARTBEAT_AT)) -le 60 ]; then echo ok; return; fi
    if [ -n "${INSTALLING_AT:-}" ] && [ $((NOW - INSTALLING_AT)) -lt 300 ]; then echo skip_install; return; fi
    if [ -n "${PREV_CHECK_AT:-}" ] && [ $((NOW - PREV_CHECK_AT)) -ge 90 ]; then echo skip_sleep; return; fi
    if [ "$UPTIME" -le 120 ]; then echo skip_launch; return; fi
    echo kill
}

# Deliberately broken wd_loop_decide: it stops at FOUR restarts in 10 min,
# not three. The runner fails if this passes every loop assertion.
wd_loop_decide() {
    if [ "${FREE_MB:-500}" -lt 500 ]; then echo disk_full; return; fi
    if [ -n "${STOPPED_AT:-}" ]; then
        if [ "${RETRIED:-0}" != 1 ] && [ $((NOW - STOPPED_AT)) -ge 1800 ]; then echo retry; else echo stay_stopped; fi
        return
    fi
    n=0
    for t in ${RESTART_TIMES:-}; do [ $((NOW - t)) -le 600 ] && n=$((n + 1)); done
    if [ "$n" -ge 4 ]; then echo stop; else echo ok; fi
}
