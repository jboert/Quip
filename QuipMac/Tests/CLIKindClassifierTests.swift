import XCTest
@testable import Quip

/// Locks `TerminalStateDetector.classifyCLI(children:)` so per-window
/// CLI routing (notably image_upload's clipboard-paste-vs-type-path
/// branch) doesn't silently regress. (GH I.)
final class CLIKindClassifierTests: XCTestCase {

    private func proc(_ name: String, pid: pid_t = 1, cpu: Double = 0) -> TerminalStateDetector.ProcessInfo {
        TerminalStateDetector.ProcessInfo(pid: pid, cpuPercent: cpu, command: name)
    }

    func test_emptyChildren_classifiesShell() {
        XCTAssertEqual(TerminalStateDetector.classifyCLI(children: []), .shell)
    }

    func test_plainShell_classifiesShell() {
        let kids = [proc("zsh"), proc("vim")]
        XCTAssertEqual(TerminalStateDetector.classifyCLI(children: kids), .shell)
    }

    func test_claudeCode_classifiesClaude() {
        let kids = [proc("zsh"), proc("node /usr/local/bin/claude")]
        XCTAssertEqual(TerminalStateDetector.classifyCLI(children: kids), .claude)
    }

    func test_bareNode_classifiesClaude() {
        // Existing TerminalStateDetector behavior: a bare node process is
        // assumed to be Claude Code (it spawns under node). Codex check
        // runs first (more specific), so a node-only tree still maps to
        // claude.
        let kids = [proc("node /some/script.js")]
        XCTAssertEqual(TerminalStateDetector.classifyCLI(children: kids), .claude)
    }

    func test_codex_classifiesCodex() {
        let kids = [proc("zsh"), proc("codex --help")]
        XCTAssertEqual(TerminalStateDetector.classifyCLI(children: kids), .codex)
    }

    func test_codexUnderNode_classifiesCodex_notClaude() {
        // Codex CLI is itself a Node app — the comm string typically
        // includes both "node" and "codex". Codex match must win because
        // it's the more specific identity. Without the order discipline,
        // image_upload would route as Claude (path-typing) and silently
        // fail to attach.
        let kids = [proc("node /usr/local/bin/codex")]
        XCTAssertEqual(TerminalStateDetector.classifyCLI(children: kids), .codex,
                       "Codex CLI runs as a node process — codex match must outrank node→claude")
    }

    func test_codexAndClaude_classifiesCodex_byOrder() {
        // Both running simultaneously: codex wins. This is unusual but
        // possible (two CLIs in tmux panes inside one shell). Without an
        // explicit choice, image_upload would silently pick Claude's path
        // and miss Codex.
        let kids = [proc("claude"), proc("codex")]
        XCTAssertEqual(TerminalStateDetector.classifyCLI(children: kids), .codex)
    }

    func test_isAIProcess_matchesAllThreeFamilies() {
        XCTAssertTrue(TerminalStateDetector.isAIProcess(comm: "claude"))
        XCTAssertTrue(TerminalStateDetector.isAIProcess(comm: "node"))
        XCTAssertTrue(TerminalStateDetector.isAIProcess(comm: "codex"))
        XCTAssertTrue(TerminalStateDetector.isAIProcess(comm: "node /path/to/codex"))
        XCTAssertFalse(TerminalStateDetector.isAIProcess(comm: "vim"))
        XCTAssertFalse(TerminalStateDetector.isAIProcess(comm: "zsh"))
    }
}
