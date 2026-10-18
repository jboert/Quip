import Foundation

/// Which agent CLIs a slash command belongs to (Q-72), so the long-press
/// palette and its search list only what works in the selected window. An
/// empty set means every agent. A window with no agent running (a plain
/// shell, or none selected) lists everything: the user may be about to start
/// either one.
enum SlashAgents {
    static func shows(_ agents: Set<CLIKind>, in window: CLIKind?) -> Bool {
        guard let window, window != .shell else { return true }
        return agents.isEmpty || agents.contains(window)
    }

    /// The members that work in `window`, in the order given.
    static func filter(_ members: [MainiOSView.SlashGroupMember], window: CLIKind?) -> [MainiOSView.SlashGroupMember] {
        members.filter { shows($0.agents, in: window) }
    }

    /// Whether a prompt's `targetAgent` fits the window's agent (a `CLIKind`
    /// raw value, as the prompt ranking context carries it). No target and
    /// "any" fit everywhere.
    static func fits(targetAgent: String?, context: String?) -> Bool {
        guard let target = targetAgent?.lowercased(), !target.isEmpty, target != "any" else { return true }
        guard let context = context?.lowercased() else { return true }
        let window = CLIKind(rawValue: context)
        guard let agent = CLIKind(rawValue: target) else { return true }
        return shows([agent], in: window)
    }
}

extension QuickButton {
    /// The agents this command works in. Codex's list was read from Codex
    /// CLI 0.163's own command table (2026-10-18); the plugin and skill
    /// commands are installed in Claude Code only.
    var agents: Set<CLIKind> {
        switch self {
        case .compact, .clearContext, .resume, .model, .initProject, .status, .permissions, .mcp:
            return [.claude, .codex]
        case .newChat, .diff, .review, .side:
            return [.codex]
        case .plan, .btw, .prd, .commitPushPr, .caveman, .ultraReview,
             .brainstorm, .writePlan, .executePlan, .context:
            return [.claude]
        default:
            return []
        }
    }
}

extension CustomButton {
    /// `agentIDs` read as agents. A kind this build does not know is dropped,
    /// so a button tagged only for it shows everywhere rather than nowhere.
    var agents: Set<CLIKind> {
        Set((agentIDs ?? []).compactMap(CLIKind.init(rawValue:)))
    }
}

extension MainiOSView.SlashGroupMember {
    var agents: Set<CLIKind> {
        switch self {
        case .builtin(let b): return b.agents
        case .custom(let c): return c.agents
        }
    }
}
