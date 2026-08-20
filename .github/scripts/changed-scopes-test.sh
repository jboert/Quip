#!/bin/bash
# Assertions for changed-scopes.sh. Pure text in, text out — no runner, no
# network, runs in well under a second. Exits non-zero on any failure.

set -uo pipefail
cd "$(dirname "$0")"

pass=0
fail=0

# expect <label> <expected-output> <input files...>
expect() {
    local label="$1" want="$2"; shift 2
    local got
    got="$(printf '%s\n' "$@" | ./changed-scopes.sh)"
    if [ "$got" = "$want" ]; then
        echo "  ok   $label"
        pass=$((pass + 1))
    else
        echo "  FAIL $label"
        echo "       want: $(echo "$want" | tr '\n' ' ')"
        echo "       got:  $(echo "$got" | tr '\n' ' ')"
        fail=$((fail + 1))
    fi
}

ALL=$'apple=true\nrust=true\nandroid=true'
NONE=$'apple=false\nrust=false\nandroid=false'
APPLE=$'apple=true\nrust=false\nandroid=false'

echo "changed-scopes"

# The case this exists for: several commits today touched only docs, and each
# one would have started two macOS runners.
expect "docs only → nothing" "$NONE" \
    "docs/superpowers/board.md" "docs/superpowers/wishlist.md"

expect "README / dotfiles → nothing" "$NONE" "README.md" ".gitignore"

expect "Mac source → apple only" "$APPLE" "QuipMac/Services/KeystrokeInjector.swift"
expect "iOS source → apple only" "$APPLE" "QuipiOS/QuipApp.swift"

# Shared/ is Swift: it compiles into both Apple targets and into nothing else.
expect "Shared → apple only" "$APPLE" "Shared/NumberedPromptDetector.swift"
expect "swiftc harness → apple only" "$APPLE" "tools/main.swift"

expect "Rust → rust only" $'apple=false\nrust=true\nandroid=false' \
    "QuipLinux/src/main.rs"
expect "Android → android only" $'apple=false\nrust=false\nandroid=true' \
    "QuipAndroid/app/src/main/Foo.kt"

expect "mixed → both scopes" $'apple=true\nrust=true\nandroid=false' \
    "Shared/MultiSelectSync.swift" "QuipLinux/src/services/log_paths.rs" "docs/x.md"

# A change to CI itself has to prove itself everywhere.
expect "workflow → everything" "$ALL" ".github/workflows/ci.yml"
expect "this script → everything" "$ALL" ".github/scripts/changed-scopes.sh"

# FAIL OPEN: no usable diff (force push, manual dispatch, shallow clone).
expect "empty input → everything" "$ALL" ""
expect "whitespace only → everything" "$ALL" "   "

echo ""
echo "$((pass + fail)) checks, $fail failures"
[ "$fail" -eq 0 ]
