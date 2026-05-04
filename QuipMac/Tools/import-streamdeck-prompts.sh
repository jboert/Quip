#!/usr/bin/env bash
# import-streamdeck-prompts.sh
# Decompiles every .scpt in a streamdeck-claude-scripts directory and
# extracts the `set the clipboard to "..."` body into one .txt file per
# script under ~/Library/Application Support/Quip/prompts/. The Quip Mac
# app picks them up automatically via the PromptLibrary FS watcher and
# pushes the new catalog to every connected phone. (wishlist §57)
#
# Usage:
#   scripts/import-streamdeck-prompts.sh ~/Projects/streamdeck-claude-scripts
#
# Idempotent — re-running overwrites .txt files, so editing a .scpt and
# re-importing reflects the change without manual cleanup.

set -euo pipefail

SRC_DIR="${1:-}"
DEST_DIR="${HOME}/Library/Application Support/Quip/prompts"

if [[ -z "$SRC_DIR" ]]; then
    echo "usage: $0 <streamdeck-scripts-directory>" >&2
    exit 1
fi
if [[ ! -d "$SRC_DIR" ]]; then
    echo "error: $SRC_DIR is not a directory" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
echo "Importing from $SRC_DIR"
echo "Writing to     $DEST_DIR"

imported=0
skipped=0
shopt -s nullglob
for scpt in "$SRC_DIR"/*.scpt; do
    name="$(basename "$scpt" .scpt)"
    decompiled="$(osadecompile "$scpt" 2>/dev/null || true)"
    # Pull the clipboard body via awk: capture text between
    # `set the clipboard to "` and the closing `"` on the same line.
    body="$(printf '%s' "$decompiled" | python3 -c '
import sys, re
src = sys.stdin.read()
# AppleScript escapes backslashes and quotes inside the literal; normalize.
m = re.search(r"set the clipboard to \"((?:[^\"\\\\]|\\\\.)*)\"", src)
if m:
    raw = m.group(1)
    raw = raw.replace("\\\\\"", "\"").replace("\\\\\\\\", "\\\\")
    print(raw)
')"
    if [[ -z "$body" ]]; then
        echo "  - $name  (no clipboard body — skipped)"
        skipped=$((skipped+1))
        continue
    fi
    out="$DEST_DIR/$name.txt"
    printf '%s\n' "$body" > "$out"
    echo "  + $name  ($(wc -c < "$out" | tr -d ' ') bytes)"
    imported=$((imported+1))
done

echo ""
echo "Imported $imported, skipped $skipped."
echo "Open Quip on iPhone → Settings → Prompts to see the catalog."
