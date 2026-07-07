#!/usr/bin/env bash
# Foundation-only assertion harness for autosuggest detection.
# Compiles Shared/AutosuggestDetector.swift + the inline harness below with
# swiftc and runs it — no Xcode, simulator, or signing required. Exits non-zero
# on any failed assertion so the autonomous loop can gate on it.
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
func expect(_ actual: Bool, _ expected: Bool, _ label: String) {
    if actual != expected {
        FileHandle.standardError.write(Data("FAIL \(label): expected \(expected), got \(actual)\n".utf8))
        failures += 1
    }
}

// US-001 — required assertions

// Ghost text: dim trailing run preceded by typed input on the last line.
let ghost = "$ ls\nsome output\nyou typed \u{1B}[2mghost text\u{1B}[0m"
expect(AutosuggestDetector.suggestionText(in: ghost), "ghost text", "dim trailing run => ghost text")
expect(AutosuggestDetector.hasSuggestion(in: ghost), true, "hasSuggestion mirrors suggestionText (some)")

// A fully-dim line (no non-dim typed prefix) is a hint, not a suggestion.
let fullyDim = "prompt\n\u{1B}[2mall of this line is dim\u{1B}[0m"
expect(AutosuggestDetector.suggestionText(in: fullyDim), nil, "fully-dim line => nil")

// Plain content with no ANSI escapes.
let plain = "line one\nyou typed something"
expect(AutosuggestDetector.suggestionText(in: plain), nil, "plain no-ANSI line => nil")
expect(AutosuggestDetector.hasSuggestion(in: plain), false, "hasSuggestion mirrors suggestionText (nil)")

// Dim text in scrollback with a plain last line must not trigger.
let scrollback = "you typed \u{1B}[2mold ghost\u{1B}[0m\nplain last line"
expect(AutosuggestDetector.suggestionText(in: scrollback), nil, "dim on earlier line => nil")

// Edge cases from the acceptance criteria.
expect(AutosuggestDetector.suggestionText(in: ""), nil, "empty content => nil")
expect(AutosuggestDetector.suggestionText(in: "\n\n"), nil, "whitespace-only content => nil")

// Grey-foreground variants also count as suggestion styling.
expect(AutosuggestDetector.suggestionText(in: "git ch\u{1B}[90meckout main\u{1B}[0m"),
       "eckout main", "SGR 90 grey fg => suggestion")
expect(AutosuggestDetector.suggestionText(in: "git ch\u{1B}[38;5;240meckout main\u{1B}[0m"),
       "eckout main", "38;5;240 grey fg => suggestion")
expect(AutosuggestDetector.suggestionText(in: "git ch\u{1B}[38;5;8meckout main\u{1B}[0m"),
       "eckout main", "38;5;8 grey fg => suggestion")

// Non-grey colors are NOT suggestions.
expect(AutosuggestDetector.suggestionText(in: "git ch\u{1B}[32meckout main\u{1B}[0m"),
       nil, "green fg => nil")
expect(AutosuggestDetector.suggestionText(in: "git ch\u{1B}[38;5;110meckout main\u{1B}[0m"),
       nil, "non-grey 8-bit fg => nil")

// SGR 22 cancels dim mid-line: trailing text is normal again => nil.
expect(AutosuggestDetector.suggestionText(in: "typed \u{1B}[2mdim\u{1B}[22m then normal"),
       nil, "dim cancelled by SGR 22 before EOL => nil")

// Trailing default-styled padding spaces don't break the run.
expect(AutosuggestDetector.suggestionText(in: "you typed \u{1B}[2mghost\u{1B}[0m   "),
       "ghost", "trailing padding spaces ignored")

// Trailing newline after the input line: last NON-EMPTY line still wins.
expect(AutosuggestDetector.suggestionText(in: "you typed \u{1B}[2mghost\u{1B}[0m\n"),
       "ghost", "trailing newline ignored")

// US-004 — inject-time guard consults the same detection.
expect(AutosuggestDetector.shouldAccept(liveContent: ghost), true,
       "shouldAccept true for ghost-text sample")
expect(AutosuggestDetector.shouldAccept(liveContent: plain), false,
       "shouldAccept false for plain no-suggestion line")

if failures > 0 {
    FileHandle.standardError.write(Data("\(failures) assertion(s) failed\n".utf8))
    exit(1)
}
print("all autosuggest assertions passed")
SWIFT

BIN="$TMPDIR/autosuggest-tests"
swiftc -o "$BIN" Shared/AutosuggestDetector.swift "$TMPDIR/main.swift"
"$BIN"
