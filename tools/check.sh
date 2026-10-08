#!/bin/bash
# Run only the test suites the current change can actually affect.
#
# The full local gate is a ~35s Mac suite, a ~10s iOS simulator suite, and a
# swiftc harness — plus an xcodegen dance around a gitignored pbxproj. Running
# all of it after editing a markdown file is the same waste the CI change fixed,
# so this reuses the SAME mapping CI uses (.github/scripts/changed-scopes.sh):
# local and CI can never disagree about what a diff touches.
#
# Usage:
#   tools/check.sh              # what is uncommitted, plus commits not yet pushed
#   tools/check.sh --all        # every suite, no filtering
#   tools/check.sh --since REF  # everything that changed since REF
#   tools/check.sh --files -    # read the path list from stdin (how this gets tested)
#
# Always prints what it skipped and why. A gate that hides what it did not run
# is worse than no gate.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# This Mac's Quip-only QA simulator ("Quip-only QA (iPhone 17 Pro Max)"). It must
# hold nothing but Quip and never be paired with the Mac: the suite launches the
# app as its test host, and a paired host once authenticated against the live
# Mac and overwrote the owner's phone settings (2026-10-07). The old "Quip QA"
# simulator is shared with another project's UI tests.
MAC_SIM_UDID_DEFAULT="D8C5154B-7030-40BA-8443-F4F9EB27C725"
IOS_SIM_UDID="${QUIP_QA_SIM_UDID:-$MAC_SIM_UDID_DEFAULT}"

mode="auto"
since_ref=""
while [ $# -gt 0 ]; do
    case "$1" in
        --all)   mode="all"; shift ;;
        --since) mode="since"; since_ref="${2:-}"; shift 2 ;;
        --files) mode="files"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- what changed

changed_files() {
    case "$mode" in
        all)   return ;;  # empty → the scope script answers "everything"
        files) cat ;;     # explicit list on stdin — the testable seam
        since)
            [ -n "$since_ref" ] || { echo "--since needs a ref" >&2; exit 2; }
            git diff --name-only "$since_ref" HEAD
            ;;
        auto)
            # Uncommitted work (staged, unstaged, untracked) …
            git status --porcelain --untracked-files=all | sed 's/^...//'
            # … plus anything committed but not yet pushed.
            local upstream
            upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
            [ -n "$upstream" ] && git diff --name-only "$upstream" HEAD
            ;;
    esac
}

FILES="$(changed_files | sort -u)"
SCOPES="$(printf '%s\n' "$FILES" | .github/scripts/changed-scopes.sh)"
eval "$SCOPES"   # sets apple / rust / android

# Apple splits further: QuipMac and QuipiOS are separate suites, and Shared/
# compiles into BOTH so it has to run both.
touched() { printf '%s\n' "$FILES" | grep -qE "$1"; }
run_mac=false; run_ios=false; run_harness=false
if [ "$apple" = "true" ]; then
    if [ "$mode" = "all" ] || [ -z "${FILES//[[:space:]]/}" ]; then
        run_mac=true; run_ios=true; run_harness=true
    else
        touched '^(QuipMac/|Shared/)' && run_mac=true
        touched '^(QuipiOS/|Shared/)' && run_ios=true
        touched '^(Shared/|tools/)'   && run_harness=true
        # A .github/ change is CI itself, which the scope script answers with
        # "run everything" — mirror that HERE, unconditionally. This used to be
        # an `if nothing else matched` fallback, which quietly did the wrong
        # thing whenever a CI edit shipped alongside a tools/ edit: the harness
        # matched, so the fallback never fired, and a workflow change was
        # verified by a 2-second swiftc run. Caught by reading this script's own
        # output on the commit that fixed CI's fail-open.
        if touched '^\.github/'; then
            run_mac=true; run_ios=true; run_harness=true
        fi
        # apple=true with nothing matched at all: a Swift-scoped path this
        # script does not recognise. Run everything rather than nothing.
        if [ "$run_mac" = "false" ] && [ "$run_ios" = "false" ] && [ "$run_harness" = "false" ]; then
            run_mac=true; run_ios=true; run_harness=true
        fi
    fi
fi

echo "── scopes: apple=$apple rust=$rust android=$android"
echo "── suites: harness=$run_harness mac=$run_mac ios=$run_ios"
echo ""

failures=0
ran=0

note_skip() { echo "── SKIPPED $1 — $2"; }

# ------------------------------------------------------------------- the gates

if [ "$run_harness" = "true" ]; then
    echo "── swiftc harness (Shared)"
    ran=$((ran + 1))
    # `| tail` means $? is TAIL's status, which is always 0 — a failing harness
    # was reported green. Same PIPESTATUS[0] rule the two Xcode gates below use.
    bash tools/run-multiselect-tests.sh | tail -2
    [ "${PIPESTATUS[0]}" -eq 0 ] || failures=$((failures + 1))
    bash tools/run-check-script-tests.sh
    [ "$?" -eq 0 ] || failures=$((failures + 1))
    echo ""
else
    note_skip "swiftc harness" "no Shared/ or tools/ change"
fi

# xcodegen writes the gitignored pbxproj on every run; each Xcode gate below
# regenerates before building and restores afterwards, always via an absolute
# repo root — running `git checkout` from inside QuipMac/ is what produced
# "pathspec ... did not match any file(s)" by hand (US-005).

# Print a suite's verdict from its captured log. The failing `error:` lines come
# first, deduped and capped, THEN the count and the verdict. This used to be one
# `grep … | tail -3`, which on a failure kept only the "Executed N tests, with 5
# failures" lines and cut every line that said WHICH test failed — a red gate
# that could not say what was red.
#
# Only compiler/XCTest/xcodebuild errors count: runtime os_log noise such as
# "[sandbox] … (error: -9)" appears on green runs and must not read as a failure.
#
# Q-37 — a suite can also go red without running a single test: the simulator
# refuses to launch the test host ("Busy (\"Application failed preflight
# checks\")"). That log has no `error:` line in the shape above, so the gate
# printed a bare TEST FAILED that read as a code failure. Say it was the
# simulator, quote the reason, and give the reboot command ($2 = the sim UDID).
summarize_suite_log() {
    grep -E '\.swift:[0-9]+(:[0-9]+)?: error:|^(xcodebuild: )?error:' "$1" | awk '!seen[$0]++' | head -15
    if ! grep -q 'TEST SUCCEEDED' "$1" \
        && grep -qE 'failed to launch|failed preflight checks|Test runner never began executing|Early unexpected exit' "$1"; then
        echo "error: the test host never launched — the simulator failed, not a test"
        grep -E '^[[:space:]]*Failure Reason:' "$1" | sed 's/^[[:space:]]*/   /' | awk '!seen[$0]++' | head -3
        [ -n "${2:-}" ] && echo "   reboot it: xcrun simctl shutdown $2 && xcrun simctl boot $2"
    fi
    grep -E "Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" "$1" | tail -2
}

# Q-31 — every Xcode suite runs under a time limit. There was none, and on
# 2026-09-25 the QuipiOS suite finished building and then sat at test launch on a
# wedged simulator for 2h18m, printing nothing (output is only shown at the end).
# A gate that can hang forever is a gate nobody runs.
#
# Pure bash on purpose: coreutils `timeout` is a Homebrew install, not something
# every Mac running this has. Returns the command's own status, or 124 (the
# coreutils convention) when the limit was hit and the command was killed.
SUITE_TIMEOUT="${QUIP_CHECK_SUITE_TIMEOUT:-1200}"

run_bounded() {
    local limit="$1" log="$2"; shift 2
    local fired="$log.timed-out"
    rm -f "$fired"
    "$@" >"$log" 2>&1 &
    local pid=$!
    (
        sleep "$limit"
        # Only a command that is STILL running has timed out. Without this, a
        # watchdog being retired (its sleep killed) ran on and marked a command
        # that had already finished as timed out.
        kill -0 "$pid" 2>/dev/null || exit 0
        : >"$fired"
        # xcodebuild owns the simulator test runner; stop the children first so
        # nothing outlives the gate, then the command itself.
        pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
        sleep 5
        pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
    ) 2>/dev/null &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    # Retire the watchdog either way (quietly — a killed job otherwise prints
    # "Terminated" into the gate's output).
    # Stop the watchdog BEFORE its sleep, so it cannot run on to its next line.
    local watchdog_kids
    watchdog_kids="$(pgrep -P "$watchdog" 2>/dev/null)"
    { kill "$watchdog"; [ -n "$watchdog_kids" ] && kill $watchdog_kids; wait "$watchdog"; } 2>/dev/null
    if [ -e "$fired" ]; then
        rm -f "$fired"
        return 124
    fi
    return "$rc"
}

report_timeout() {
    echo "error: $1 TIMED OUT after ${SUITE_TIMEOUT}s and was killed (set QUIP_CHECK_SUITE_TIMEOUT to change the limit)"
    [ -n "${2:-}" ] && echo "   a wedged simulator is the usual cause — xcrun simctl shutdown $2 && xcrun simctl boot $2"
    return 0
}

if [ "$run_mac" = "true" ]; then
    echo "── QuipMac suite"
    ran=$((ran + 1))
    (cd QuipMac && xcodegen generate >/dev/null 2>&1)
    mac_log="$(mktemp "${TMPDIR:-/tmp}/quip-mac-check.XXXXXX")"
    run_bounded "$SUITE_TIMEOUT" "$mac_log" xcodebuild -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -configuration Debug test
    mac_status=$?
    [ "$mac_status" -eq 124 ] && report_timeout "QuipMac suite"
    summarize_suite_log "$mac_log"
    rm -f "$mac_log"
    [ "$mac_status" -eq 0 ] || failures=$((failures + 1))
    git -C "$ROOT" checkout QuipMac/QuipMac.xcodeproj/project.pbxproj >/dev/null 2>&1 || true
    echo ""
else
    note_skip "QuipMac suite" "no QuipMac/ or Shared/ change"
fi

# The QuipiOS scheme embeds a Watch app, and xcodebuild refuses to build the
# scheme AT ALL when no watchOS *simulator runtime* is installed — having the
# watchOS SDK is not enough. That turns an unrelated machine gap into "QuipiOS
# suite FAILED", which says nothing about the change under test and blocks the
# pre-commit hook. When the runtime is missing, generate from a spec with the
# QuipWatch target stripped and say so, so the iOS code still gets tested and
# the report stays honest about what ran.
ios_generate() {
    # Do not use `xcrun ... | grep -q` under pipefail here: grep exits as soon
    # as it sees watchOS, xcrun then receives SIGPIPE, and the successful match
    # is reported as a failed pipeline. That silently selected the no-Watch
    # fallback even on machines with both watchOS runtimes installed.
    local simulator_runtimes
    simulator_runtimes="$(xcrun simctl list runtimes 2>/dev/null || true)"
    if [[ "$simulator_runtimes" == *watchOS* ]]; then
        (cd "$ROOT/QuipiOS" && xcodegen generate --quiet)
        return $?
    fi
    python3 - "$ROOT/QuipiOS/project.yml" "$ROOT/QuipiOS/project.nowatch.yml" <<'PY'
import sys
lines = open(sys.argv[1]).read().split('\n')
out, i = [], 0
while i < len(lines):
    line = lines[i]
    if line == '  QuipWatch:':
        i += 1
        while i < len(lines) and (lines[i].startswith('    ') or lines[i].strip() == ''):
            i += 1
        continue
    if line == '    dependencies:' and i + 1 < len(lines) and lines[i+1].strip() == '- target: QuipWatch':
        i += 1
        while i < len(lines) and lines[i].startswith('      '):
            i += 1
        continue
    out.append(line)
    i += 1
open(sys.argv[2], 'w').write('\n'.join(out))
PY
    # xcodegen records the spec path inside the generated project, so the file
    # has to outlive the build; the gate below removes it once the suite ran.
    (cd "$ROOT/QuipiOS" && xcodegen generate --spec project.nowatch.yml --quiet)
    echo "   note: no watchOS simulator runtime — ran without the QuipWatch target"
}

if [ "$run_ios" = "true" ]; then
    echo "── QuipiOS suite"
    ran=$((ran + 1))
    if ios_generate; then
        # The generated project records Signing.xcconfig relative to QuipiOS/.
        # Keep Xcode's working directory anchored there as well. Capture first
        # and filter second: this makes the invoked command identical to the
        # direct suite and preserves xcodebuild's status without PIPESTATUS.
        ios_log="$(mktemp "${TMPDIR:-/tmp}/quip-ios-check.XXXXXX")"
        ios_suite() { cd "$ROOT/QuipiOS" && xcodebuild -project QuipiOS.xcodeproj -scheme QuipiOS -destination "id=$IOS_SIM_UDID" test; }
        run_bounded "$SUITE_TIMEOUT" "$ios_log" ios_suite
        ios_status=$?
        [ "$ios_status" -eq 124 ] && report_timeout "QuipiOS suite" "$IOS_SIM_UDID"
        summarize_suite_log "$ios_log" "$IOS_SIM_UDID"
        rm -f "$ios_log"
        [ "$ios_status" -eq 0 ] || failures=$((failures + 1))
    else
        echo "error: failed to generate QuipiOS.xcodeproj"
        failures=$((failures + 1))
    fi
    rm -f "$ROOT/QuipiOS/project.nowatch.yml"
    git -C "$ROOT" checkout QuipiOS/QuipiOS.xcodeproj/project.pbxproj >/dev/null 2>&1 || true
    echo ""
else
    note_skip "QuipiOS suite" "no QuipiOS/ or Shared/ change"
fi

# QuipLinux and QuipAndroid are not this machine's lane. Say so rather than
# pretending they passed — an unrun suite reported as green is the exact
# failure mode this script exists to avoid.
[ "$rust" = "true" ]    && note_skip "QuipLinux (cargo)"  "not built on this machine — run it on the Linux side"
[ "$android" = "true" ] && note_skip "QuipAndroid (gradle)" "not built on this machine"

echo ""
if [ "$ran" -eq 0 ]; then
    echo "nothing to verify — no change touches a suite this machine runs"
    exit 0
fi
if [ "$failures" -eq 0 ]; then
    echo "$ran suite(s) ran, all green"
    exit 0
fi
echo "$ran suite(s) ran, $failures FAILED"
exit 1
