#!/usr/bin/env bash
# Compile the Foundation-only Shared multi-select logic together with the
# assertion harness (tools/MultiSelectTests.swift) via swiftc and run it.
# No Xcode / simulator / code signing — the autonomous loop's gate for the
# multiselect-precheck-sync stories. Exits non-zero on any failed assertion.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC=(
  Shared/NumberedPromptDetector.swift
  Shared/MultiSelectSync.swift
  tools/main.swift
)

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
BIN="$TMPDIR/multiselect-tests"

swiftc -o "$BIN" "${SRC[@]}"
"$BIN"
