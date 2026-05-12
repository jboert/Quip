# CloudflareTunnel.swift `Process` invocation audit

**Date:** 2026-05-06
**Closes:** GH #15 ([HIGH] Audit CloudflareTunnel.swift Process invocation for shell-injection)
**Auditor:** Claude (Opus 4.7), eb-branch tip `df21a32`

## Scope

Every `Process` invocation reachable from `QuipMac/Services/CloudflareTunnel.swift`. The concern: an attacker who can influence any input that flows into a child-process argument could break out into shell metacharacters (`;`, `&&`, `$(…)`, backticks) and gain code execution under the Quip Mac app's privileges.

## Result

**No shell-injection vector exists.**

CloudflareTunnel.swift has two `Process` invocations. Both use `Process.executableURL` + `Process.arguments[]` (the argv-array form), which delegates to `posix_spawn`/`execve` directly. The kernel does not invoke a shell on this path. Shell metacharacters in argv elements are passed verbatim to the child program as opaque bytes — they cannot start a subshell, redirect, or chain commands.

This was a deliberate design decision documented in the source comment at `CloudflareTunnel.swift:205-208`:

> Run cloudflared directly (no shell wrapper) — avoids shell-quoting hazards on paths with spaces, and lets us redirect output via the child's `--logfile` flag rather than `> file 2>&1`.

## Invocation 1 — `start(localPort:)` at L210-219

```swift
let shell = Process()
shell.executableURL = URL(fileURLWithPath: cfPath)
shell.arguments = [
    "tunnel",
    "--url", "http://localhost:\(proxyPort)",
    "--logfile", Self.logPath,
    "--log-format", "json",
    "--loglevel", "info",
    "--no-autoupdate",
]
```

**Inputs to argv:**

| Element | Source | Attacker-controlled? |
|---------|--------|----------------------|
| `cfPath` | `Bundle.main.path(forResource: "cloudflared", ofType: nil)` (L186), fallback `/opt/homebrew/bin/cloudflared` | No — Bundle.main resolves inside the app bundle (signed); fallback is hardcoded literal |
| `proxyPort` | `UInt16` constant `8766` declared at L36 | No — numeric type cannot encode shell metacharacters; `\(UInt16)` produces only decimal digits |
| `Self.logPath` | `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!` + `appendingPathComponent("Quip/tunnel.log")` (L166-169) | No — Caches dir is OS-resolved; `appendingPathComponent` does proper path-joining, no shell interpolation. Even if the user's home contained `;rm`, Process.arguments treats it as one argv element, not shell input |
| All `--flag` strings | String literals | No |

**Verdict:** Safe.

## Invocation 2 — `killOrphanedCloudflared()` at L341-343

```swift
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
proc.arguments = ["-f", "cloudflared tunnel"]
```

All literals. No external input flows to argv. Output is parsed with `Int32(line.trimmingCharacters(in: .whitespaces))` (L351) which rejects anything that isn't a signed-int parseable string before `kill()` receives it — the parsed value is also compared to `myPid` to skip self.

**Verdict:** Safe.

## What was checked but is not in scope

`grep -rn '/bin/sh\|/bin/bash\|"sh"\|"bash"\|launchPath\b' QuipMac --include="*.swift"` returned one hit, in `TerminalStateDetector.swift:143`, which is a `Set<String>` of shell **names** used to identify shell processes by `comm` field — not a `Process` invocation. No `/bin/sh -c` invocations exist anywhere under `QuipMac/`.

Other `Process()` callers under `QuipMac/Services/` (`TerminalStateDetector`, `TailscaleService`, `KokoroTTS`, `DiagnosticsBundle`, `KeystrokeInjector`) are out of scope for this audit (GH #15 is CloudflareTunnel-specific). A spot-check confirms each uses the same argv-array form, but a full audit of those sites should be filed as a follow-up if it isn't already covered by the GH #26 META hardening tracker.

## Regression coverage

`QuipMac/Tests/CloudflareTunnelArgsTests.swift` (added in this commit) locks the structure of `cloudflaredArguments(proxyPort:logPath:)`:

- Argv[0] is exactly `"tunnel"` (no shell wrapper)
- The `--url` argument is exactly `"http://localhost:<digits>"` for arbitrary `UInt16` values including 0 / 1 / 65535
- The `--logfile` argument is the verbatim string passed in, even when it contains shell-special characters (`'; rm -rf /'`)
- No argv element contains an unbalanced `-c`, `;`, `&&`, `||`, or `$(`
- Argv length is exactly 10 (catches accidental `concat` regressions)

If a future change wraps the invocation in `/bin/sh -c "..."` or builds args by string concatenation, these tests fail.

## Closing #15

Audit confirms the existing implementation is safe by construction. No code change needed beyond:

1. Extracting the argv build into a static helper `cloudflaredArguments(proxyPort:logPath:)` so it's purely-functional and testable.
2. The regression tests above.
3. This audit doc.
