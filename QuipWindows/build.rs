//! Embeds the application manifest in `Quip.exe` (spec 5.2): per-monitor DPI
//! aware v2, so every Win32 coordinate the host reads or sets is in physical
//! pixels and no scaling math is needed. `embed-manifest` writes the resource
//! itself, so this works the same with MSVC, with MinGW and when
//! cross-compiling from the Mac.
//!
//! It links into the binaries only. Test binaries get the same awareness at
//! run time from `Win32Platform::new`.
//!
//! Also stamps the git commit into `QUIP_GIT_SHA` (read with `option_env!`)
//! for the selftest report. No git, or not a checkout: no stamp.

use std::path::Path;
use std::process::Command;

use embed_manifest::manifest::DpiAwareness;
use embed_manifest::{embed_manifest, new_manifest};

fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?.trim().to_string();
    (!s.is_empty()).then_some(s)
}

fn stamp_git_sha() {
    let Some(sha) = git(&["rev-parse", "--short=12", "HEAD"]) else { return };
    println!("cargo:rustc-env=QUIP_GIT_SHA={sha}");
    // Rerun when HEAD moves: HEAD itself (a checkout), the branch it names
    // (a commit), and packed-refs. Only files that exist, or cargo reruns
    // this every build.
    let mut watched = vec!["HEAD".to_string(), "packed-refs".to_string()];
    if let Some(branch) = git(&["symbolic-ref", "-q", "HEAD"]) {
        watched.push(branch);
    }
    for name in watched {
        if let Some(path) = git(&["rev-parse", "--git-path", &name]) {
            if Path::new(&path).exists() {
                println!("cargo:rerun-if-changed={path}");
            }
        }
    }
}

fn main() {
    if std::env::var_os("CARGO_CFG_WINDOWS").is_some() {
        let manifest = new_manifest("Quip.Windows.Host").dpi_awareness(DpiAwareness::PerMonitorV2);
        if let Err(e) = embed_manifest(manifest) {
            panic!("cannot embed the Windows manifest: {e}");
        }
    }
    stamp_git_sha();
    println!("cargo:rerun-if-changed=build.rs");
}
