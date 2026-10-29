import Foundation

// quip-claude-hook — Claude Code PostToolUse hook for Bash (Q-87).
//
// Installed by Quip's "Show Claude's previews on phone" switch. Reads the
// hook payload on stdin; if the command `open`ed previewable files, drops a
// report in Quip's inbox. It must never affect Claude: every path exits 0
// and prints nothing.

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = try? JSONDecoder().decode(ClaudeHookInput.self, from: input),
      payload.tool_name == "Bash",
      let command = payload.tool_input?.command,
      OpenCommandParser.mightOpen(command) else { exit(0) }

let cwd = payload.cwd ?? FileManager.default.currentDirectoryPath
let parsed = OpenCommandParser.parse(command, cwd: cwd)
guard !parsed.paths.isEmpty || parsed.skippedExpansion > 0 else { exit(0) }

let env = ProcessInfo.processInfo.environment
let report = ClaudeHookReport(
    at: Date().timeIntervalSince1970,
    sessionId: payload.session_id,
    cwd: cwd,
    paths: parsed.paths,
    tty: ProcessTTY.nearestTTY(),
    itermSessionId: ClaudeHookReport.itermSessionUUID(env["ITERM_SESSION_ID"]),
    termSessionId: env["TERM_SESSION_ID"],
    skippedExpansion: parsed.skippedExpansion
)
try? report.write(to: ClaudeHookReport.inboxDirectory)
exit(0)
