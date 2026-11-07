//! The tray icon, drawn at run time at the size Windows asks for (no icon
//! resource to compile): a teal disc with a white ring and tail, a plain
//! "Q". `pixels` is pure and tested; `create` turns it into an HICON.

/// Teal, opaque, as `0xAARRGGBB`.
pub const DISC: u32 = 0xFF1F_7A8C;
pub const MARK: u32 = 0xFFFF_FFFF;
pub const CLEAR: u32 = 0x0000_0000;

/// `size` x `size` pixels, rows top to bottom, each `0xAARRGGBB` with
/// straight alpha (what a 32-bit icon bitmap holds).
pub fn pixels(size: usize) -> Vec<u32> {
    let s = size as f64;
    let c = (s - 1.0) / 2.0;
    let (ring_in, ring_out) = (0.22 * s, 0.34 * s);
    let tail = |x: f64, y: f64| {
        // Distance from the segment (0.58s, 0.58s) -> (0.86s, 0.86s).
        let (ax, bx) = (0.58 * s, 0.86 * s);
        let t = (((x - ax) + (y - ax)) / (2.0 * (bx - ax))).clamp(0.0, 1.0);
        let (px, py) = (ax + t * (bx - ax), ax + t * (bx - ax));
        ((x - px).powi(2) + (y - py).powi(2)).sqrt() <= 0.07 * s
    };
    let mut out = Vec::with_capacity(size * size);
    for row in 0..size {
        for col in 0..size {
            let (x, y) = (col as f64, row as f64);
            let d = ((x - c).powi(2) + (y - c).powi(2)).sqrt();
            let px = if (ring_in..=ring_out).contains(&d) || tail(x, y) {
                MARK
            } else if d <= s / 2.0 {
                DISC
            } else {
                CLEAR
            };
            out.push(px);
        }
    }
    out
}

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
