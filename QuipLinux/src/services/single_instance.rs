// Process-wide mutex that prevents two quip-linux daemons from running for the
// same user. Without it, a second launch silently loses the bind on
// 0.0.0.0:8765 (the OS lets the older one keep the port) but its GTK UI still
// renders, so the user toggles a window in instance B while iOS is still
// connected to instance A. Result: phone shows "No windows" while the desktop
// app insists the window is enabled. See git log around this commit for the
// debugging story.
//
// We use flock() on a file in $XDG_RUNTIME_DIR (or /tmp/$UID fallback). flock
// is per-fd and the kernel releases it automatically when the process exits,
// even on SIGKILL — no stale-lock cleanup to write. We deliberately leak the
// File so the lock stays held for the entire process lifetime.

use nix::libc;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::io::AsRawFd;
use std::path::PathBuf;

pub enum AcquireOutcome {
    Acquired,
    AlreadyHeldBy(Option<i32>),
}

pub fn acquire_or_report() -> AcquireOutcome {
    let path = lock_path();

    let mut file = match OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&path)
    {
        Ok(f) => f,
        Err(e) => {
            // If we can't even open the lockfile, don't refuse to start —
            // a missing /run/user dir is a worse failure mode than letting
            // a duplicate slip through. Log and continue.
            tracing::warn!("single-instance: cannot open {}: {e}", path.display());
            return AcquireOutcome::Acquired;
        }
    };

    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        let holder = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| s.trim().parse::<i32>().ok());
        return AcquireOutcome::AlreadyHeldBy(holder);
    }

    // Record our pid for diagnostics. Best-effort — losing this write doesn't
    // affect the lock itself.
    let _ = file.set_len(0);
    let _ = writeln!(file, "{}", std::process::id());

    // Keep the fd alive for the lifetime of the process. flock releases on
    // last close, which is what we want at exit; until then, hold on.
    Box::leak(Box::new(file));
    AcquireOutcome::Acquired
}

fn lock_path() -> PathBuf {
    if let Ok(rt) = std::env::var("XDG_RUNTIME_DIR") {
        let p = PathBuf::from(rt);
        if p.exists() {
            return p.join("quip-linux.lock");
        }
    }
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/quip-linux-{uid}.lock"))
}
