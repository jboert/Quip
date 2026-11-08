//! The tray icon, drawn at run time at the size Windows asks for: a teal
//! disc with a white ring and tail, a plain "Q". `pixels` (in `icon_art`,
//! which `build.rs` also uses for the exe's `.ico` resource) is pure and
//! tested; `create` turns it into an HICON.

pub use super::icon_art::{pixels, CLEAR, DISC, MARK};

#[cfg(windows)]
pub use self::win32::create;

#[cfg(windows)]
mod win32 {
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::WindowsAndMessaging::{CreateIcon, GetSystemMetrics, HICON, SM_CXSMICON};

    /// The icon at the small-icon size for this DPI (16 px at 100 %).
    pub fn create() -> Result<HICON, String> {
        // SAFETY: plain value argument.
        let size = unsafe { GetSystemMetrics(SM_CXSMICON) }.clamp(16, 256) as usize;
        let color: Vec<u8> = super::pixels(size).iter().flat_map(|p| p.to_le_bytes()).collect();
        // A 1-bit AND mask, rows padded to 16 bits, all zero: the alpha in
        // the color bitmap decides.
        let mask = vec![0u8; size.div_ceil(16) * 2 * size];
        // SAFETY: null module name = this exe; no other arguments.
        let module = unsafe { GetModuleHandleW(None) }.map_err(|e| e.to_string())?;
        // SAFETY: both buffers hold exactly the bits a `size` x `size`
        // icon with a 1-bit mask and a 32-bit color plane needs, and live
        // for the call.
        unsafe { CreateIcon(module, size as i32, size as i32, 1, 32, mask.as_ptr(), color.as_ptr()) }
            .map_err(|e| format!("cannot create the tray icon: {e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn corners_are_clear_the_middle_is_the_disc_and_the_ring_is_white() {
        for size in [16usize, 20, 24, 32] {
            let p = pixels(size);
            assert_eq!(p.len(), size * size);
            let at = |x: usize, y: usize| p[y * size + x];
            assert_eq!(at(0, 0), CLEAR, "{size}");
            assert_eq!(at(size - 1, 0), CLEAR, "{size}");
            assert_eq!(at(size / 2, size / 2), DISC, "{size}: the Q's hole");
            assert!(p.iter().filter(|&&c| c == MARK).count() > size, "{size}: a visible ring");
            assert_eq!(at(size / 2, (size as f64 * 0.22) as usize), MARK, "{size}: top of the ring");
        }
    }
}
