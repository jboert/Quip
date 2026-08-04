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

MAC_SIM_UDID_DEFAULT="9A204976-5E83-4909-B88C-7C06D3FD69B2"  # "Quip QA — iPhone 17 Pro Max"
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
        # apple=true with no Swift directory matched means the scope came from
        # something global — a .github change, which is CI itself. Mirror what
        # CI does there and run everything rather than quietly running nothing.
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
    bash tools/run-multiselect-tests.sh | tail -2 || failures=$((failures + 1))
    echo ""
else
    note_skip "swiftc harness" "no Shared/ or tools/ change"
fi

# xcodegen writes the gitignored pbxproj on every run; each Xcode gate below
# regenerates before building and restores afterwards, always via an absolute
# repo root — running `git checkout` from inside QuipMac/ is what produced
# "pathspec ... did not match any file(s)" by hand (US-005).

if [ "$run_mac" = "true" ]; then
    echo "── QuipMac suite"
    ran=$((ran + 1))
    (cd QuipMac && xcodegen generate >/dev/null 2>&1)
    xcodebuild -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -configuration Debug test 2>&1 \
        | grep -E "error:|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" | tail -3
    # PIPESTATUS[0] is xcodebuild's own status, not grep's.
    [ "${PIPESTATUS[0]}" -eq 0 ] || failures=$((failures + 1))
    git -C "$ROOT" checkout QuipMac/QuipMac.xcodeproj/project.pbxproj >/dev/null 2>&1 || true
    echo ""
else
    note_skip "QuipMac suite" "no QuipMac/ or Shared/ change"
fi

if [ "$run_ios" = "true" ]; then
    echo "── QuipiOS suite"
    ran=$((ran + 1))
    (cd QuipiOS && xcodegen generate >/dev/null 2>&1)
    xcodebuild -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination "id=$IOS_SIM_UDID" test 2>&1 \
        | grep -E "error:|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" | tail -3
    [ "${PIPESTATUS[0]}" -eq 0 ] || failures=$((failures + 1))
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
