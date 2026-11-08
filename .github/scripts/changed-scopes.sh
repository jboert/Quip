#!/bin/bash
# Map a list of changed paths (one per line, on stdin) to the CI scopes that
# need to run. Emits `key=true|false` lines for GITHUB_OUTPUT.
#
# Why this exists: `apple-mac` and `apple-ios` run on macOS runners, which
# GitHub bills at 10x the Linux rate. Before this, a docs-only or Linux-only
# pull request started both of them — the most expensive jobs in the workflow,
# to compile code the change could not have touched.
#
# FAIL OPEN. Any doubt about what changed (no diff range, a force push, a
# manual dispatch) must run everything: a wasted runner costs money, a skipped
# one ships a regression. The caller passes an empty list to mean "unknown".
#
# Tested by .github/scripts/changed-scopes-test.sh — run that after any edit.

set -euo pipefail

files="$(cat)"

# Unknown/empty input → run everything.
if [ -z "${files//[[:space:]]/}" ]; then
    echo "apple=true"
    echo "rust=true"
    echo "android=true"
    echo "windows=true"
    exit 0
fi

apple=false
rust=false
android=false
windows=false

while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
        # Swift lives in exactly these four places. Shared/ compiles into both
        # Apple targets (it is Swift, so QuipLinux and QuipAndroid never see it)
        # and tools/ is the swiftc harness for that same Shared code.
        # Q-91: the Windows host. tools/fake-windows/ is its fake, not Swift,
        # so it must match before the tools/* (swiftc harness) arm.
        QuipWindows/*|tools/fake-windows/*|tools/build-windows.sh)
            windows=true ;;
        # The shared fixtures are read by the Swift tests AND the Windows host
        # (Q-91 shared vectors), so a fixture change runs both.
        Shared/Tests/Fixtures/*)
            apple=true; windows=true ;;
        QuipMac/*|QuipiOS/*|Shared/*|tools/*)
            apple=true ;;
        QuipLinux/*)
            rust=true ;;
        QuipAndroid/*)
            android=true ;;
        # The workflow (or this script) changing means the change itself is what
        # needs proving — run every job.
        .github/*)
            apple=true; rust=true; android=true; windows=true ;;
        # Everything else — docs, the board, READMEs, .gitignore — builds
        # nothing. That is the whole point.
        *) ;;
    esac
done <<< "$files"

echo "apple=$apple"
echo "rust=$rust"
echo "android=$android"
echo "windows=$windows"
