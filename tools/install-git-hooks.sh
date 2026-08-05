#!/bin/bash
# Install the repo's tracked git hooks (tools/git-hooks/) into this clone.
#
# Hooks are opt-in per clone: git never runs a hook out of a tracked directory
# on its own, and this repo already sets core.hooksPath explicitly, so this
# links into whatever path that resolves to rather than repointing it — moving
# core.hooksPath would silently disable any hook already installed there.
#
# Symlinks, not copies, so an edit to tools/git-hooks/ takes effect immediately
# and nobody ends up debugging a stale copy.
#
#   tools/install-git-hooks.sh            # install
#   tools/install-git-hooks.sh --uninstall
#   tools/install-git-hooks.sh --status

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC="$ROOT/tools/git-hooks"

# core.hooksPath may be relative to the repo root, or unset (→ .git/hooks).
hooks_path="$(git config --get core.hooksPath || true)"
if [ -z "$hooks_path" ]; then
    DEST="$(git rev-parse --git-path hooks)"
elif [ "${hooks_path#/}" != "$hooks_path" ]; then
    DEST="$hooks_path"
else
    DEST="$ROOT/$hooks_path"
fi

mode="install"
case "${1:-}" in
    --uninstall) mode="uninstall" ;;
    --status)    mode="status" ;;
    "")          ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

mkdir -p "$DEST"

for src in "$SRC"/*; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    dest="$DEST/$name"

    case "$mode" in
        status)
            if [ "$(readlink "$dest" 2>/dev/null)" = "$src" ]; then
                echo "installed   $name → $dest"
            elif [ -e "$dest" ]; then
                echo "OTHER FILE  $name — $dest exists but is not our hook"
            else
                echo "missing     $name"
            fi
            ;;
        uninstall)
            if [ "$(readlink "$dest" 2>/dev/null)" = "$src" ]; then
                rm -f "$dest"
                echo "removed     $name"
            elif [ -e "$dest" ]; then
                # Never delete a hook this script did not create.
                echo "left alone  $name — $dest is not our symlink"
            fi
            ;;
        install)
            if [ -e "$dest" ] && [ "$(readlink "$dest" 2>/dev/null)" != "$src" ]; then
                echo "REFUSING    $name — $dest already exists and is not our symlink" >&2
                echo "            move it aside first, then re-run." >&2
                exit 1
            fi
            chmod +x "$src"
            ln -sfn "$src" "$dest"
            echo "installed   $name → $dest"
            ;;
    esac
done

if [ "$mode" = "install" ]; then
    echo ""
    echo "pre-commit now runs tools/check.sh on the staged paths."
    echo "Skip once with:  QUIP_SKIP_CHECK=1 git commit    (or --no-verify)"
    echo "Remove with:     tools/install-git-hooks.sh --uninstall"
fi
