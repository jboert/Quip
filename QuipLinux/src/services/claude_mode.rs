use crate::protocol::messages::ClaudeMode;

/// Scrape Claude Code's current mode from a terminal buffer.
///
/// Mirrors `QuipMac/Services/ClaudeModeDetector.swift`. Returns `None` if no
/// indicator is found — caller decides whether to treat that as "normal" (when
/// they have other evidence Claude is running) or "unknown".
///
/// Only the last `tail_line_count` lines of the buffer are inspected: Claude
/// Code renders its mode footer at the bottom of the screen, and scanning
/// older prose would false-positive on chat history that mentions
/// "plan mode on" as text.
pub fn detect(buffer: &str, tail_line_count: usize) -> Option<ClaudeMode> {
    let lines: Vec<&str> = buffer.split('\n').collect();
    let start = lines.len().saturating_sub(tail_line_count);
    let tail: String = lines[start..].join("\n").to_lowercase();

    // Plan wins if both somehow appear — plan is the more specific state.
    if tail.contains("plan mode on") {
        Some(ClaudeMode::Plan)
    } else if tail.contains("auto-accept edits on") {
        Some(ClaudeMode::AutoAccept)
    } else {
        None
    }
}

/// Convenience: 40-line tail to match Mac's default.
pub fn detect_default(buffer: &str) -> Option<ClaudeMode> {
    detect(buffer, 40)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plan_mode_from_footer() {
        let buffer = "lots of prose above\nsome claude output\n⏵⏵ plan mode on  (shift+tab to cycle)";
        assert_eq!(detect_default(buffer), Some(ClaudeMode::Plan));
    }

    #[test]
    fn auto_accept_from_footer() {
        let buffer = ">>> running edits...\n⏵⏵ auto-accept edits on  (shift+tab to cycle)";
        assert_eq!(detect_default(buffer), Some(ClaudeMode::AutoAccept));
    }

    #[test]
    fn normal_mode_returns_none() {
        let buffer = "$ claude\nWelcome to Claude Code.\n> your prompt here_";
        assert_eq!(detect_default(buffer), None);
    }

    #[test]
    fn empty_buffer_returns_none() {
        assert_eq!(detect_default(""), None);
    }

    #[test]
    fn mention_in_old_prose_ignored_by_tail_window() {
        // 60 filler lines push the "plan mode on" mention above the 40-line scan
        // region, so it shouldn't be caught.
        let filler = std::iter::repeat("filler line").take(60).collect::<Vec<_>>().join("\n");
        let buffer = format!(
            "I read a paper that said \"plan mode on\" changes the behavior.\n{filler}\n$ bare prompt"
        );
        assert_eq!(detect_default(&buffer), None);
    }

    #[test]
    fn both_indicators_plan_wins() {
        let buffer = "auto-accept edits on\nplan mode on";
        assert_eq!(detect_default(buffer), Some(ClaudeMode::Plan));
    }

    #[test]
    fn case_insensitive() {
        assert_eq!(detect_default("Plan Mode ON"), Some(ClaudeMode::Plan));
    }
}
