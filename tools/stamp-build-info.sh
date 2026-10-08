#!/bin/bash
# Stamp the built app's Info.plist with the git commit and the build time, so
# an installed Quip can always say which code it is. Runs as a post-build
# phase on every build (QuipMac/project.yml, QuipiOS/project.yml); Xcode signs
# after all phases, so the edit is inside the signature.
#
# Keys written (read by Shared/BuildInfo.swift):
#   QuipBuildCommit  short hash, "-dirty" when tracked files differ from HEAD
#                    (the regenerated project.pbxproj never counts, US-005)
#   QuipBuildDate    local build time, "YYYY-MM-DD HH:MM"
set -euo pipefail

plist="${TARGET_BUILD_DIR:-}/${INFOPLIST_PATH:-}"
if [ ! -f "$plist" ]; then
  echo "stamp-build-info: no Info.plist at '$plist', nothing stamped" >&2
  exit 0
fi

repo="${SRCROOT:-$(pwd)}/.."
commit="unknown"
if git -C "$repo" rev-parse --short=7 HEAD >/dev/null 2>&1; then
  commit="$(git -C "$repo" rev-parse --short=7 HEAD)"
  if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no -- . ':(exclude)*.pbxproj' 2>/dev/null)" ]; then
    commit="${commit}-dirty"
  fi
fi
date="$(date '+%Y-%m-%d %H:%M')"

pb=/usr/libexec/PlistBuddy
for key in QuipBuildCommit QuipBuildDate; do
  "$pb" -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
done
"$pb" -c "Add :QuipBuildCommit string $commit" "$plist"
"$pb" -c "Add :QuipBuildDate string $date" "$plist"
echo "stamp-build-info: $commit $date -> $plist"
