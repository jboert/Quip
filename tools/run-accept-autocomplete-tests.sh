#!/usr/bin/env bash
# Foundation-only assertion harness for the accept-autocomplete feature.
# Compiles Shared/TerminalKeyBytes.swift + the inline harness below with swiftc
# and runs it — no Xcode, simulator, or signing required. Exits non-zero on any
# failed assertion so the autonomous loop can gate on it.
set -euo pipefail

cd "$(dirname "$0")/.."

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/main.swift" <<'SWIFT'
import Foundation

var failures = 0
func expect(_ actual: String?, _ expected: String?, _ label: String) {
    if actual != expected {
        FileHandle.standardError.write(Data("FAIL \(label): expected \(String(describing: expected)), got \(String(describing: actual))\n".utf8))
        failures += 1
    }
}

// US-001 — CSI table
expect(TerminalKeyBytes.csi(for: "right"), "\u{1B}[C", "csi(right)")
expect(TerminalKeyBytes.csi(for: "RIGHT"), "\u{1B}[C", "csi(RIGHT) case-insensitive")
expect(TerminalKeyBytes.csi(for: "up"),    "\u{1B}[A", "csi(up)")
expect(TerminalKeyBytes.csi(for: "down"),  "\u{1B}[B", "csi(down)")
expect(TerminalKeyBytes.csi(for: "left"),  "\u{1B}[D", "csi(left)")
expect(TerminalKeyBytes.csi(for: "end"),   "\u{1B}[F", "csi(end)")
expect(TerminalKeyBytes.csi(for: "bogus"), nil,        "csi(bogus)")

if failures > 0 {
    FileHandle.standardError.write(Data("\(failures) assertion(s) failed\n".utf8))
    exit(1)
}
print("all accept-autocomplete assertions passed")
SWIFT

BIN="$TMPDIR/accept-autocomplete-tests"
swiftc -o "$BIN" Shared/TerminalKeyBytes.swift "$TMPDIR/main.swift"
"$BIN"
