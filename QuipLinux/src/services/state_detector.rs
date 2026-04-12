use std::collections::{HashMap, HashSet};
use std::fs;
use std::time::Instant;

use crate::protocol::types::TerminalState;
use tracing::{error, warn};

/// Stored CPU sample for delta-based CPU% estimation.
#[derive(Debug, Clone)]
struct CpuSample {
    total_ticks: u64,
    timestamp: Instant,
}

pub struct StateDetector {
    states: HashMap<String, TerminalState>,
    tracked: HashMap<String, u32>,
    cpu_threshold: f64,
    prev_cpu: HashMap<u32, CpuSample>,
    /// Windows where Claude/node processes are currently running (regardless of CPU).
    /// Used to drive the "thinking" indicator on iOS.
    pub windows_with_claude: HashSet<String>,
}

impl StateDetector {
    pub fn new(cpu_threshold: f64) -> Self {
        Self {
            states: HashMap::new(),
            tracked: HashMap::new(),
            cpu_threshold,
            prev_cpu: HashMap::new(),
            windows_with_claude: HashSet::new(),
        }
    }

    /// Start tracking a terminal window by its shell PID.
    pub fn track(&mut self, window_id: &str, shell_pid: u32) {
        self.tracked.insert(window_id.to_string(), shell_pid);
        self.states
            .entry(window_id.to_string())
            .or_insert(TerminalState::Neutral);
    }

    /// Stop tracking a terminal window.
    pub fn untrack(&mut self, window_id: &str) {
        self.tracked.remove(window_id);
        self.states.remove(window_id);
    }

    /// Mark a window as having active speech-to-text input.
    pub fn set_stt_active(&mut self, window_id: &str) {
        self.states
            .insert(window_id.to_string(), TerminalState::SttActive);
    }

    /// Clear STT state, resetting to Neutral.
    pub fn clear_stt(&mut self, window_id: &str) {
        if self.states.get(window_id) == Some(&TerminalState::SttActive) {
            self.states
                .insert(window_id.to_string(), TerminalState::Neutral);
        }
    }

    /// Get the current state for a window.
    pub fn get_state(&self, window_id: &str) -> Option<TerminalState> {
        self.states.get(window_id).copied()
    }

    /// Iterator over tracked window IDs.
    pub fn tracked_ids(&self) -> impl Iterator<Item = &str> {
        self.tracked.keys().map(|s| s.as_str())
    }

    /// Check if a window is being tracked.
    pub fn is_tracked(&self, window_id: &str) -> bool {
        self.tracked.contains_key(window_id)
    }

    /// Poll all tracked windows and update their terminal states.
    /// Returns a list of (window_id, new_state) for any windows whose state changed.
    pub fn poll_all(&mut self) -> Vec<(String, TerminalState)> {
        let mut changes = Vec::new();

        let entries: Vec<(String, u32)> = self
            .tracked
            .iter()
            .map(|(k, v)| (k.clone(), *v))
            .collect();

        for (window_id, shell_pid) in entries {
            // Skip windows with active STT — their state is managed externally.
            if self.states.get(&window_id) == Some(&TerminalState::SttActive) {
                continue;
            }

            let (new_state, has_claude) = self.detect_state(shell_pid);

            // Update Claude process presence for thinking indicator
            if has_claude {
                self.windows_with_claude.insert(window_id.clone());
            } else {
                self.windows_with_claude.remove(&window_id);
            }

            let prev = self.states.get(&window_id).copied().unwrap_or_default();
            if new_state != prev {
                self.states.insert(window_id.clone(), new_state);
                changes.push((window_id, new_state));
            }
        }

        changes
    }

    /// Detect the terminal state for a given shell PID by inspecting /proc.
    /// Returns (state, has_claude_process) — the bool tracks process presence
    /// regardless of CPU for the "thinking" indicator.
    fn detect_state(&mut self, shell_pid: u32) -> (TerminalState, bool) {
        let children = match find_claude_children(shell_pid) {
            Some(pids) if !pids.is_empty() => pids,
            _ => return (TerminalState::WaitingForInput, false),
        };

        // Check CPU usage of the claude/node children.
        let now = Instant::now();
        let mut any_busy = false;

        for pid in &children {
            let total_ticks = match read_process_cpu_ticks(*pid) {
                Some(t) => t,
                None => continue,
            };

            if let Some(prev) = self.prev_cpu.get(pid) {
                let tick_delta = total_ticks.saturating_sub(prev.total_ticks);
                let elapsed = now.duration_since(prev.timestamp).as_secs_f64();

                if elapsed > 0.0 {
                    // Approximate ticks per second (usually 100 on Linux).
                    let ticks_per_sec = ticks_per_second();
                    let cpu_pct = (tick_delta as f64 / (elapsed * ticks_per_sec)) * 100.0;
                    if cpu_pct > self.cpu_threshold {
                        any_busy = true;
                    }
                }
            }

            // Store sample for next poll.
            self.prev_cpu.insert(
                *pid,
                CpuSample {
                    total_ticks,
                    timestamp: now,
                },
            );
        }

        if any_busy {
            (TerminalState::Neutral, true)
        } else {
            (TerminalState::WaitingForInput, true)
        }
    }
}

/// Find ALL descendant processes of `shell_pid` whose comm contains "claude" or "node".
/// Walks the full process tree to catch nested children.
fn find_claude_children(shell_pid: u32) -> Option<Vec<u32>> {
    // Parse all processes from /proc into (pid, ppid, comm)
    let proc_dir = match fs::read_dir("/proc") {
        Ok(d) => d,
        Err(_) => return None,
    };

    struct ProcEntry {
        pid: u32,
        ppid: u32,
        comm: String,
    }

    let mut all_procs = Vec::new();
    for entry in proc_dir.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        let pid: u32 = match name_str.parse() {
            Ok(p) => p,
            Err(_) => continue,
        };

        let stat_path = format!("/proc/{pid}/stat");
        let stat_content = match fs::read_to_string(&stat_path) {
            Ok(s) => s,
            Err(_) => continue,
        };

        if let Some((comm, ppid)) = parse_stat_comm_ppid(&stat_content) {
            all_procs.push(ProcEntry { pid, ppid, comm });
        }
    }

    // Walk the tree: find all descendants of shell_pid
    let mut descendants: HashSet<u32> = HashSet::new();
    descendants.insert(shell_pid);
    let mut changed = true;
    while changed {
        changed = false;
        for proc in &all_procs {
            if descendants.contains(&proc.ppid) && !descendants.contains(&proc.pid) {
                descendants.insert(proc.pid);
                changed = true;
            }
        }
    }
    descendants.remove(&shell_pid);

    // Filter to claude/node processes among descendants
    let child_pids: Vec<u32> = all_procs
        .iter()
        .filter(|p| descendants.contains(&p.pid))
        .filter(|p| {
            let comm_lower = p.comm.to_ascii_lowercase();
            comm_lower.contains("claude") || comm_lower.contains("node")
        })
        .map(|p| p.pid)
        .collect();

    Some(child_pids)
}

/// Parse the comm field (inside parens) and ppid from a /proc/*/stat line.
/// Fields: pid (comm) state ppid ...
fn parse_stat_comm_ppid(stat: &str) -> Option<(String, u32)> {
    // comm is enclosed in parentheses and may itself contain parens.
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    if close <= open {
        return None;
    }
    let comm = &stat[open + 1..close];
    // Fields after comm: state ppid ...
    let rest = &stat[close + 2..]; // skip ") "
    let mut fields = rest.split_whitespace();
    let _state = fields.next()?;
    let ppid: u32 = fields.next()?.parse().ok()?;
    Some((comm.to_string(), ppid))
}

/// Read the total CPU ticks (utime + stime) for a process from /proc/{pid}/stat.
fn read_process_cpu_ticks(pid: u32) -> Option<u64> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let close = stat.rfind(')')?;
    let rest = &stat[close + 2..];
    let fields: Vec<&str> = rest.split_whitespace().collect();
    // After (comm), fields are: state(0) ppid(1) pgrp(2) session(3) tty_nr(4)
    // tpgid(5) flags(6) minflt(7) cminflt(8) majflt(9) cmajflt(10)
    // utime(11) stime(12) ...
    let utime: u64 = fields.get(11)?.parse().ok()?;
    let stime: u64 = fields.get(12)?.parse().ok()?;
    Some(utime + stime)
}

/// Get the system clock tick rate (CLK_TCK), typically 100 on Linux.
fn ticks_per_second() -> f64 {
    // On Linux, CLK_TCK is almost universally 100. We could query via
    // libc::sysconf(libc::_SC_CLK_TCK) but 100 is safe as a default.
    100.0
}
