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

if [ "$failures" -ne 0 ]; then
    echo "$checks check-script assertions, $failures failures"
    exit 1
fi

echo "$checks check-script assertions passed"
