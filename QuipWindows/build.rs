//! Embeds the application manifest in `Quip.exe` (spec 5.2): per-monitor DPI
//! aware v2, so every Win32 coordinate the host reads or sets is in physical
//! pixels and no scaling math is needed. `embed-manifest` writes the resource
//! itself, so this works the same with MSVC, with MinGW and when
//! cross-compiling from the Mac.
//!
//! It links into the binaries only. Test binaries get the same awareness at
//! run time from `Win32Platform::new`.

use embed_manifest::manifest::DpiAwareness;
use embed_manifest::{embed_manifest, new_manifest};

fn main() {
    if std::env::var_os("CARGO_CFG_WINDOWS").is_some() {
        let manifest = new_manifest("Quip.Windows.Host").dpi_awareness(DpiAwareness::PerMonitorV2);
        if let Err(e) = embed_manifest(manifest) {
            panic!("cannot embed the Windows manifest: {e}");
        }
    }
    println!("cargo:rerun-if-changed=build.rs");
}
