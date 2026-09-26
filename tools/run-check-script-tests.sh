#!/usr/bin/env bash
# Fast invariants for the local Apple gate. These catch project-generation
# regressions before a simulator build spends tens of seconds rediscovering
# that Signing.xcconfig resolved outside QuipiOS/.
set -uo pipefail

cd "$(dirname "$0")/.."

checks=0
failures=0

expect_present() {
    local pattern="$1" file="$2" label="$3"
    checks=$((checks + 1))
    if ! grep -qE "$pattern" "$file"; then
        echo "FAIL: $label"
        failures=$((failures + 1))
    fi
}

expect_absent() {
    local pattern="$1" file="$2" label="$3"
    checks=$((checks + 1))
    if grep -qE "$pattern" "$file"; then
        echo "FAIL: $label"
        failures=$((failures + 1))
    fi
}

# XcodeGen 2.46 plus intermediate grouping hoists the `.` source beneath a
# physical `..` group because this target also imports ../Shared. Config files
# then resolve at the repository root. Flat groups keep Signing.xcconfig beside
# project.yml, which is where both direct builds and tools/check.sh need it.
expect_present '^  createIntermediateGroups: false$' QuipiOS/project.yml \
    "QuipiOS must keep flat XcodeGen groups so Signing.xcconfig resolves locally"

# Under `set -o pipefail`, grep -q exits early after matching watchOS and can
# SIGPIPE simctl, making a machine with Watch runtimes take the no-Watch path.
expect_absent 'simctl list runtimes.*\|.*grep -q' tools/check.sh \
    "watch runtime detection must not use a grep -q pipeline under pipefail"

expect_present 'cd "\$ROOT/QuipiOS".*xcodebuild -project QuipiOS\.xcodeproj' tools/check.sh \
    "the iOS gate must invoke Xcode from the generated project's directory"

# Q-31 — a suite must not be able to hang the gate. Exercise the real
# `run_bounded` from check.sh (extracted, not re-implemented here).
expect_status() {
    local want="$1" got="$2" label="$3"
    checks=$((checks + 1))
    if [ "$got" != "$want" ]; then
        echo "FAIL: $label (want status $want, got $got)"
        failures=$((failures + 1))
    fi
}

bounded_src="$(sed -n '/^run_bounded()/,/^}/p' tools/check.sh)"
if [ -z "$bounded_src" ]; then
    checks=$((checks + 1)); failures=$((failures + 1))
    echo "FAIL: check.sh must define run_bounded (per-suite timeout)"
else
    eval "$bounded_src"
    tlog="$(mktemp "${TMPDIR:-/tmp}/quip-bounded-test.XXXXXX")"

    started=$SECONDS
    run_bounded 1 "$tlog" sleep 30; st=$?
    expect_status 124 "$st" "a command that outlives its limit reports 124 (timed out)"
    checks=$((checks + 1))
    if [ $((SECONDS - started)) -gt 10 ]; then
        echo "FAIL: run_bounded waited $((SECONDS - started))s on a 1s limit — the hung command was not killed"
        failures=$((failures + 1))
    fi

    run_bounded 5 "$tlog" false; st=$?
    expect_status 1 "$st" "a command that fails in time keeps its own exit status"

    run_bounded 5 "$tlog" sh -c 'echo captured; exit 0'; st=$?
    expect_status 0 "$st" "a command that passes in time returns 0"
    expect_present '^captured$' "$tlog" "run_bounded captures the command's output into the log"

    rm -f "$tlog"
fi

expect_present 'run_bounded .*xcodebuild -project QuipMac/QuipMac\.xcodeproj' tools/check.sh \
    "the QuipMac suite must run under run_bounded"
expect_present 'run_bounded .*ios_suite' tools/check.sh \
    "the QuipiOS suite must run under run_bounded"

if [ "$failures" -ne 0 ]; then
    echo "$checks check-script assertions, $failures failures"
    exit 1
fi

echo "$checks check-script assertions passed"
