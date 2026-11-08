//! The Quip mark as pixels, and as a `.ico` file. No crate imports: `build.rs`
//! includes this file (`#[path]`) to write the exe's icon resource, and the
//! tray draws the same pixels at run time (`tray::icon`).

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

/// The sizes in the exe's `.ico` (Explorer picks one per view).
pub const ICO_SIZES: [usize; 5] = [16, 24, 32, 48, 256];

/// A 32-bit `.ico` holding `pixels(size)` for each of `sizes` (1..=256),
/// each image a bottom-up BMP with an all-zero AND mask (the alpha decides).
pub fn ico_bytes(sizes: &[usize]) -> Vec<u8> {
    let images: Vec<Vec<u8>> = sizes.iter().map(|&size| bmp_image(size)).collect();
    let mut out = Vec::new();
    let put16 = |out: &mut Vec<u8>, v: u16| out.extend_from_slice(&v.to_le_bytes());
    let put32 = |out: &mut Vec<u8>, v: u32| out.extend_from_slice(&v.to_le_bytes());
    put16(&mut out, 0); // reserved
    put16(&mut out, 1); // type: icon
    put16(&mut out, sizes.len() as u16);
    let mut offset = 6 + 16 * sizes.len();
    for (&size, image) in sizes.iter().zip(&images) {
        let side = if size >= 256 { 0 } else { size as u8 }; // 0 means 256
        out.extend_from_slice(&[side, side, 0, 0]); // no palette, reserved
        put16(&mut out, 1); // planes
        put16(&mut out, 32); // bits per pixel
        put32(&mut out, image.len() as u32);
        put32(&mut out, offset as u32);
        offset += image.len();
    }
    for image in images {
        out.extend_from_slice(&image);
    }
    out
}

/// One `.ico` image: BITMAPINFOHEADER (height doubled: color plus mask),
/// the color rows bottom-up as B, G, R, A, then a zero 1-bit mask with rows
/// padded to 32 bits.
fn bmp_image(size: usize) -> Vec<u8> {
    let mask_row = size.div_ceil(32) * 4;
    let mut out = Vec::with_capacity(40 + size * size * 4 + mask_row * size);
    for v in [40u32, size as u32, (size * 2) as u32] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&1u16.to_le_bytes()); // planes
    out.extend_from_slice(&32u16.to_le_bytes()); // bits per pixel
    for v in [0u32, (size * size * 4) as u32, 0, 0, 0, 0] {
        // compression (none), image size, resolution x/y, palette counts
        out.extend_from_slice(&v.to_le_bytes());
    }
    let px = pixels(size);
    for row in (0..size).rev() {
        for p in &px[row * size..(row + 1) * size] {
            out.extend_from_slice(&p.to_le_bytes());
        }
    }
    out.resize(out.len() + mask_row * size, 0);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u16_at(b: &[u8], at: usize) -> u16 {
        u16::from_le_bytes([b[at], b[at + 1]])
    }
    fn u32_at(b: &[u8], at: usize) -> u32 {
        u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
    }

    #[test]
    fn the_ico_header_lists_five_32_bit_images_inside_the_file() {
        let ico = ico_bytes(&ICO_SIZES);
        assert_eq!((u16_at(&ico, 0), u16_at(&ico, 2), u16_at(&ico, 4)), (0, 1, 5), "reserved, type icon, count");
        let mut end_of_last = 6 + 16 * 5;
        for (i, size) in ICO_SIZES.iter().enumerate() {
            let e = 6 + 16 * i;
            let side = if *size == 256 { 0 } else { *size as u8 };
            assert_eq!((ico[e], ico[e + 1]), (side, side), "entry {i}: width/height (0 = 256)");
            assert_eq!((ico[e + 2], ico[e + 3]), (0, 0), "entry {i}: no palette, reserved");
            assert_eq!((u16_at(&ico, e + 4), u16_at(&ico, e + 6)), (1, 32), "entry {i}: planes, bits");
            let (len, off) = (u32_at(&ico, e + 8) as usize, u32_at(&ico, e + 12) as usize);
            let mask_row = size.div_ceil(32) * 4;
            assert_eq!(len, 40 + size * size * 4 + mask_row * size, "entry {i}: header + color + mask");
            assert_eq!(off, end_of_last, "entry {i}: images follow each other");
            assert!(off + len <= ico.len(), "entry {i}: inside the file");
            assert_eq!(u32_at(&ico, off), 40, "entry {i}: BITMAPINFOHEADER");
            assert_eq!(u32_at(&ico, off + 4) as usize, *size, "entry {i}: width");
            assert_eq!(u32_at(&ico, off + 8) as usize, size * 2, "entry {i}: height counts the mask");
            assert_eq!(u16_at(&ico, off + 14), 32, "entry {i}: 32 bpp");
            assert_eq!(u32_at(&ico, off + 20) as usize, size * size * 4, "entry {i}: color plane size");
            end_of_last = off + len;
        }
        assert_eq!(end_of_last, ico.len(), "nothing after the last image");
    }

    #[test]
    fn the_16_px_image_reads_back_as_the_tray_pixels() {
        let ico = ico_bytes(&ICO_SIZES);
        let off = u32_at(&ico, 6 + 12) as usize + 40;
        // Rows are stored bottom-up, each pixel as B, G, R, A.
        let mut got = vec![0u32; 16 * 16];
        for stored in 0..16 {
            let row = 15 - stored;
            for col in 0..16 {
                got[row * 16 + col] = u32_at(&ico, off + (stored * 16 + col) * 4);
            }
        }
        assert_eq!(got, pixels(16));
        let mask = &ico[off + 16 * 16 * 4..off + 16 * 16 * 4 + 4 * 16];
        assert!(mask.iter().all(|b| *b == 0), "the AND mask is clear: the alpha decides");
    }
}
