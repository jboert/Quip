#!/bin/bash
# Build the shippable Quip for Windows (Q-91, spec 9) on the Mac:
#   tools/build-windows.sh                       build and check QuipWindows/dist/Quip.exe
#   tools/build-windows.sh --check-imports FILE  check `objdump -p` output only (FILE or - for stdin)
#   tools/build-windows.sh --check-stamp STAMP FILE
#                                                check a stamp ("0.1.0 (<sha>[-dirty])") against
#                                                `git status --porcelain` output (FILE or -)
#
# Steps: (a) toolchain present, else print the install commands and exit 2;
# (b) cargo release build for x86_64-pc-windows-gnu; (c) copy to
# QuipWindows/dist/Quip.exe (gitignored); (d) every imported DLL is a Windows
# system DLL on the list below, or an api-ms-win-* API set (a MinGW runtime
# DLL such as libgcc_s_seh-1.dll would not be on the owner's PC); (e) the PE
# subsystem is Windows GUI (no console window); (f) the HEAD commit is
# stamped in the exe, and `-dirty` in the stamp agrees with this script's own
# `git status` of the build inputs (a stale or lying stamp fails); (g) print
# size, SHA-256 and the stamp.
#
# It writes only to QuipWindows/target/ and QuipWindows/dist/, and never
# copies the exe anywhere else: getting it to the PC is the owner's call.
#
# Exit: 0 ok, 1 a check failed, 2 toolchain missing or bad arguments.
set -euo pipefail

TARGET=x86_64-pc-windows-gnu
OBJDUMP=x86_64-w64-mingw32-objdump

# The DLLs Quip.exe may import, lower case. A new one is a reviewed
# one-line change here, never a silent new runtime dependency.
ALLOWED_DLLS="
advapi32.dll
bcrypt.dll
bcryptprimitives.dll
dwmapi.dll
gdi32.dll
iphlpapi.dll
kernel32.dll
ntdll.dll
ole32.dll
oleaut32.dll
propsys.dll
shell32.dll
user32.dll
userenv.dll
version.dll
ws2_32.dll
"

# What the exe is built from, relative to QuipWindows/. The same list as
# BUILD_INPUTS in QuipWindows/build.rs (a test holds them equal): `-dirty`
# means a tracked file here differs from HEAD.
BUILD_INPUTS="src build.rs Cargo.toml Cargo.lock .cargo rust-toolchain.toml"

# check_stamp STAMP: reads `git status --porcelain` of the build inputs on
# stdin. Returns 1 when the stamp says clean and the tree is not, or says
# -dirty and the tree is clean (a stamp left from an older build).
check_stamp() {
    local stamp="$1" changes
    changes="$(sed '/^[[:space:]]*$/d')"
    case "$stamp" in
        *-dirty\)*)
            if [ -z "$changes" ]; then
                echo "stamp check: Quip.exe is stamped -dirty but the build inputs are clean (a stale build?)" >&2
                return 1
            fi
            ;;
        *)
            if [ -n "$changes" ]; then
                echo "stamp check: Quip.exe is stamped clean but the build inputs have uncommitted changes:" >&2
                echo "$changes" >&2
                return 1
            fi
            ;;
    esac
    echo "stamp check: ok"
}

# Reads `objdump -p` output on stdin. Prints each DLL that is not allowed
# and returns 1 if there was one, or if there were no imports at all (an
# objdump that failed says nothing, which must not pass).
check_imports() {
    local names bad=0 n
    names="$(sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p' | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
    if [ -z "$names" ]; then
        echo "import check: no DLL Name lines (not objdump -p output?)" >&2
        return 1
    fi
    while IFS= read -r n; do
        [ -z "$n" ] && continue
        case "$n" in
            api-ms-win-*) continue ;;
        esac
        if ! grep -qxF "$n" <<<"$ALLOWED_DLLS"; then
            echo "import check: Quip.exe imports $n, which is not a Windows system DLL on the list in tools/build-windows.sh" >&2
            bad=1
        fi
    done <<<"$names"
    return "$bad"
}

if [ "${1:-}" = "--check-imports" ]; then
    [ $# -eq 2 ] || { echo "usage: $0 --check-imports <file|->" >&2; exit 2; }
    if [ "$2" = "-" ]; then
        check_imports && echo "import check: ok"
    else
        [ -f "$2" ] || { echo "no such file: $2" >&2; exit 2; }
        check_imports <"$2" && echo "import check: ok"
    fi
    exit $?
fi
if [ "${1:-}" = "--check-stamp" ]; then
    [ $# -eq 3 ] || { echo "usage: $0 --check-stamp <stamp> <file|->" >&2; exit 2; }
    if [ "$3" = "-" ]; then
        check_stamp "$2"
    else
        [ -f "$3" ] || { echo "no such file: $3" >&2; exit 2; }
        check_stamp "$2" <"$3"
    fi
    exit $?
fi
[ $# -eq 0 ] || { echo "usage: $0 [--check-imports <file|-> | --check-stamp <stamp> <file|->]" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/QuipWindows"

# (a) toolchain
missing=""
rustup target list --installed 2>/dev/null | grep -qx "$TARGET" || missing="$missing $TARGET"
for tool in x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres "$OBJDUMP"; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    echo "missing:$missing" >&2
    echo "install once, then run this again:" >&2
    echo "  rustup target add $TARGET" >&2
    echo "  brew install mingw-w64" >&2
    exit 2
fi

# (b) build
cargo build --release --target "$TARGET" --manifest-path "$CRATE/Cargo.toml"
built="$CRATE/target/$TARGET/release/Quip.exe"
[ -f "$built" ] || { echo "no $built after the build" >&2; exit 1; }

# (c) copy, inside dist/ only
mkdir -p "$CRATE/dist"
exe="$CRATE/dist/Quip.exe"
cp "$built" "$exe"

failed=0
dump="$("$OBJDUMP" -p "$exe")"

# (d) imports
# Here-strings, not pipes: with pipefail, `grep -q` closing the pipe early
# would fail the writer (SIGPIPE) and so the check.
if check_imports <<<"$dump"; then
    echo "import check: ok ($(sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p' <<<"$dump" | tr '[:upper:]' '[:lower:]' | sort -u | wc -l | tr -d ' ') DLLs)"
else
    failed=1
fi

# (e) subsystem
if grep -Eq '^Subsystem[[:space:]]+0+2[[:space:]]+\(Windows GUI\)' <<<"$dump"; then
    echo "subsystem: Windows GUI"
else
    echo "subsystem check: Quip.exe is not a Windows GUI program (a console window would open)" >&2
    grep -E '^Subsystem' <<<"$dump" >&2 || true
    failed=1
fi

# (f) stamp: the build string build.rs compiled in, for this HEAD
version="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$CRATE/Cargo.toml" | head -1)"
sha="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
stamp="$(LC_ALL=C grep -aoE "$version \\($sha(-dirty)?\\)" "$exe" | head -1 || true)"
if [ -n "$stamp" ]; then
    echo "stamp: Quip for Windows $stamp"
    # shellcheck disable=SC2086  # BUILD_INPUTS is a word list
    tree="$(cd "$CRATE" && git status --porcelain --untracked-files=no -- $BUILD_INPUTS)"
    check_stamp "$stamp" <<<"$tree" || failed=1
    case "$stamp" in
        *-dirty*) echo "note: built from a tree with uncommitted changes; commit first for a build you ship" >&2 ;;
    esac
else
    echo "stamp check: HEAD $sha is not stamped in Quip.exe" >&2
    failed=1
fi

# (g) report
echo "exe: $exe"
echo "size: $(wc -c <"$exe" | tr -d ' ') bytes"
echo "sha256: $(shasum -a 256 "$exe" | cut -d' ' -f1)"
exit "$failed"
