//! Embeds the application manifest in `Quip.exe` (spec 5.2): per-monitor DPI
//! aware v2, so every Win32 coordinate the host reads or sets is in physical
//! pixels and no scaling math is needed. `embed-manifest` writes the resource
//! itself, so this works the same with MSVC, with MinGW and when
//! cross-compiling from the Mac.
//!
//! It links into the binaries only. Test binaries get the same awareness at
//! run time from `Win32Platform::new`.
//!
//! Also stamps the build (spec 9): `QUIP_BUILD` = `build_info::describe`
//! (version, 12-char commit, `-dirty`) and `QUIP_GIT_SHA` = the commit. No
//! git, or not a checkout: the version alone and no `QUIP_GIT_SHA`.

use std::path::Path;
use std::process::Command;

#[path = "src/build_info/describe.rs"]
mod describe;
#[path = "src/tray/icon_art.rs"]
#[allow(dead_code)]
mod icon_art;

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

/// Sets `QUIP_BUILD` (`describe`) and, with git, `QUIP_GIT_SHA`. Dirty =
/// a tracked file differs from HEAD (untracked files do not count: a stray
/// scratch file in the checkout does not change what was built).
fn stamp_build() -> String {
    let version = std::env::var("CARGO_PKG_VERSION").unwrap_or_default();
    let sha = git(&["rev-parse", "--short=12", "HEAD"]);
    let dirty = sha.is_some() && git(&["status", "--porcelain", "--untracked-files=no"]).is_some();
    let build = describe::describe(&version, sha.as_deref(), dirty);
    println!("cargo:rustc-env=QUIP_BUILD={build}");
    let Some(sha) = sha else { return build };
    println!("cargo:rustc-env=QUIP_GIT_SHA={sha}");
    // Rerun when HEAD moves: HEAD itself (a checkout), the branch it names
    // (a commit), and packed-refs. Only files that exist, or cargo reruns
    // this every build.
    // The index too (a `git add` or a commit), so `-dirty` follows them.
    let mut watched = vec!["HEAD".to_string(), "packed-refs".to_string(), "index".to_string()];
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
    build
}

/// `quip.rc` for the exe: the Quip icon (`icon_art`, so Explorer and the
/// tray show the same mark) and a version resource (spec 9). The icon is
/// next to it in `OUT_DIR`, which the resource compiler searches.
fn resource_script(version: &str, build: &str) -> String {
    let n = |key: &str| std::env::var(key).ok().and_then(|v| v.parse::<u16>().ok()).unwrap_or(0);
    let numbers =
        format!("{},{},{},0", n("CARGO_PKG_VERSION_MAJOR"), n("CARGO_PKG_VERSION_MINOR"), n("CARGO_PKG_VERSION_PATCH"));
    // An rc string holds no `"` or `\`; neither appears in a version or a stamp.
    let clean = |s: &str| s.replace(['"', '\\'], "");
    let (version, build) = (clean(version), clean(build));
    format!(
        r#"1 ICON "quip.ico"
1 VERSIONINFO
FILEVERSION {numbers}
PRODUCTVERSION {numbers}
FILEFLAGSMASK 0x3F
FILEFLAGS 0x0
FILEOS 0x40004
FILETYPE 0x1
FILESUBTYPE 0x0
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "CompanyName", "Quip"
      VALUE "FileDescription", "Quip for Windows"
      VALUE "FileVersion", "{version}"
      VALUE "InternalName", "Quip"
      VALUE "OriginalFilename", "Quip.exe"
      VALUE "ProductName", "Quip"
      VALUE "ProductVersion", "{version}"
      VALUE "Comments", "{build}"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"#
    )
}

fn embed_resources(build: &str) {
    let out = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap_or_default());
    let version = std::env::var("CARGO_PKG_VERSION").unwrap_or_default();
    if let Err(e) = std::fs::write(out.join("quip.ico"), icon_art::ico_bytes(&icon_art::ICO_SIZES)) {
        panic!("cannot write quip.ico: {e}");
    }
    let rc = out.join("quip.rc");
    if let Err(e) = std::fs::write(&rc, resource_script(&version, build)) {
        panic!("cannot write quip.rc: {e}");
    }
    // Required: a release without its icon and version would ship quietly.
    if let Err(e) = embed_resource::compile(&rc, embed_resource::NONE).manifest_required() {
        panic!("cannot compile the icon and version resource: {e}");
    }
}

fn main() {
    let build = stamp_build();
    if std::env::var_os("CARGO_CFG_WINDOWS").is_some() {
        let manifest = new_manifest("Quip.Windows.Host").dpi_awareness(DpiAwareness::PerMonitorV2);
        if let Err(e) = embed_manifest(manifest) {
            panic!("cannot embed the Windows manifest: {e}");
        }
        embed_resources(&build);
    }
    // An edit to the crate's sources makes the tree dirty, so rerun then
    // too (a directory is scanned for any change).
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=build.rs");
}
