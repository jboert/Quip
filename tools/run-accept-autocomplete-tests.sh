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

// US-002 — the Mac injector's iTerm2 write expression for an arrow key is
// derivable from the CSI bytes: ESC + tail  ->  ((character id 27) & "tail").
// This locks the byte contract KeystrokeInjector.iTerm2WriteExpression depends on
// without needing AppKit (the injector itself is grep-verified in the loop).
func iTerm2Expr(fromCSI key: String) -> String? {
    guard let csi = TerminalKeyBytes.csi(for: key), csi.hasPrefix("\u{1B}") else { return nil }
    let tail = String(csi.dropFirst())   // drop the ESC
    return "((character id 27) & \"\(tail)\")"
}
expect(iTerm2Expr(fromCSI: "up"),    "((character id 27) & \"[A\")", "iTerm2 expr up")
expect(iTerm2Expr(fromCSI: "down"),  "((character id 27) & \"[B\")", "iTerm2 expr down")
expect(iTerm2Expr(fromCSI: "right"), "((character id 27) & \"[C\")", "iTerm2 expr right (accept autocomplete)")

if failures > 0 {
    FileHandle.standardError.write(Data("\(failures) assertion(s) failed\n".utf8))
    exit(1)
}
print("all accept-autocomplete assertions passed")
SWIFT

BIN="$TMPDIR/accept-autocomplete-tests"
swiftc -o "$BIN" Shared/TerminalKeyBytes.swift "$TMPDIR/main.swift"
"$BIN"
