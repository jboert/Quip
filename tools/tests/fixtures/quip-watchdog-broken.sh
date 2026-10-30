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
