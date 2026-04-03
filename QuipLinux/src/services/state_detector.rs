use std::collections::HashMap;
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
}

impl StateDetector {
    pub fn new(cpu_threshold: f64) -> Self {
        Self {
            states: HashMap::new(),
            tracked: HashMap::new(),
            cpu_threshold,
            prev_cpu: HashMap::new(),
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

            let new_state = self.detect_state(shell_pid);
            let prev = self.states.get(&window_id).copied().unwrap_or_default();
            if new_state != prev {
                self.states.insert(window_id.clone(), new_state);
                changes.push((window_id, new_state));
            }
        }

        changes
    }

    /// Detect the terminal state for a given shell PID by inspecting /proc.
    fn detect_state(&mut self, shell_pid: u32) -> TerminalState {
        let children = match find_claude_children(shell_pid) {
            Some(pids) if !pids.is_empty() => pids,
            _ => return TerminalState::WaitingForInput,
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
            TerminalState::Neutral
        } else {
            TerminalState::WaitingForInput
        }
    }
}

/// Find child processes of `shell_pid` whose comm contains "claude" or "node".
fn find_claude_children(shell_pid: u32) -> Option<Vec<u32>> {
    let task_dir = format!("/proc/{shell_pid}/task");
    // First, enumerate all direct child PIDs via /proc/{pid}/task/{tid}/children
    // or fall back to scanning /proc for processes whose ppid matches shell_pid.
    let mut child_pids = Vec::new();

    // Scan /proc for children of the shell.
    let proc_dir = match fs::read_dir("/proc") {
        Ok(d) => d,
        Err(_) => return None,
    };

    for entry in proc_dir.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        let pid: u32 = match name_str.parse() {
            Ok(p) => p,
            Err(_) => continue,
        };

        // Read the stat file to get ppid (field 4) and comm (field 2).
        let stat_path = format!("/proc/{pid}/stat");
        let stat_content = match fs::read_to_string(&stat_path) {
            Ok(s) => s,
            Err(_) => continue,
        };

        if let Some((comm, ppid)) = parse_stat_comm_ppid(&stat_content) {
            if ppid == shell_pid {
                let comm_lower = comm.to_ascii_lowercase();
                if comm_lower.contains("claude") || comm_lower.contains("node") {
                    child_pids.push(pid);
                }
            }
        }
    }

    // Also check task threads of the shell itself for relevant names.
    if let Ok(tasks) = fs::read_dir(&task_dir) {
        for entry in tasks.flatten() {
            let tid_str = entry.file_name();
            let tid: u32 = match tid_str.to_string_lossy().parse() {
                Ok(t) => t,
                Err(_) => continue,
            };

            let stat_path = format!("/proc/{shell_pid}/task/{tid}/stat");
            if let Ok(content) = fs::read_to_string(&stat_path) {
                if let Some((comm, _)) = parse_stat_comm_ppid(&content) {
                    let comm_lower = comm.to_ascii_lowercase();
                    if comm_lower.contains("claude") || comm_lower.contains("node") {
                        // Use the tid as a pseudo-pid for CPU tracking.
                        if !child_pids.contains(&tid) {
                            child_pids.push(tid);
                        }
                    }
                }
            }
        }
    }

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
