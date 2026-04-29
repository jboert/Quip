//! Canonical on-disk locations for Quip's append-only diagnostic logs.
//!
//! These used to live in `/tmp/`, which is world-readable on shared hosts
//! and gets wiped on reboot — taking breadcrumbs that explain "what happened
//! last time" with it. They now live under XDG conventions: `$XDG_STATE_HOME`
//! when available (default `~/.local/state/quip/`), falling back to the
//! cache dir when `state_dir()` isn't reported by the platform.

use std::path::PathBuf;

/// Parent directory for all Quip logs.
fn base_dir() -> PathBuf {
    if let Some(dirs) = directories::ProjectDirs::from("dev", "quip", "quip") {
        if let Some(state) = dirs.state_dir() {
            return state.to_path_buf();
        }
        return dirs.cache_dir().to_path_buf();
    }
    // Last-ditch fallback if even HOME isn't readable. /tmp is the same
    // place we used to live, so behaviour degrades to the old default.
    PathBuf::from("/tmp/quip")
}

fn ensure_dir(path: &PathBuf) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
}

/// Kokoro TTS daemon lifecycle and synth events.
pub fn kokoro() -> PathBuf {
    let p = base_dir().join("kokoro.log");
    ensure_dir(&p);
    p
}
