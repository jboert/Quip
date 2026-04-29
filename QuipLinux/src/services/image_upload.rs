use std::fs;
use std::path::{Path, PathBuf};

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};

use crate::protocol::messages::ImageUploadMessage;

#[derive(Debug)]
pub enum ImageUploadError {
    InvalidBase64,
    InvalidPath,
    NotAnImage,
    MimeTypeMismatch { detected: ImageFormat, declared: String },
    WriteFailed(std::io::Error),
}

impl std::fmt::Display for ImageUploadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidBase64 => write!(f, "invalid base64 image data"),
            Self::InvalidPath => write!(f, "image path failed sandbox check"),
            Self::NotAnImage => write!(f, "payload is not a recognized image format"),
            Self::MimeTypeMismatch { detected, declared } => {
                write!(f, "mimeType mismatch: detected {detected:?}, declared {declared}")
            }
            Self::WriteFailed(e) => write!(f, "write failed: {e}"),
        }
    }
}

impl std::error::Error for ImageUploadError {}

/// Decoded image formats we'll accept on the wire. Mirrors `ImageFormat` in
/// `QuipMac/Services/ImageUploadHandler.swift` — the Mac and Linux receivers
/// have to enforce the same allow-list or a message that's accepted on one
/// platform will be rejected on the other.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageFormat {
    Png,
    Jpeg,
    Gif,
    Webp,
    Heic,
}

impl ImageFormat {
    /// Detect the image format from the leading bytes of a decoded payload.
    /// Returns `None` for anything that doesn't sniff as a known image —
    /// random binary blobs, scripts, archives, etc. all land here.
    pub fn detect(bytes: &[u8]) -> Option<ImageFormat> {
        // 12 bytes is enough to disambiguate every format we accept.
        if bytes.len() < 12 {
            return None;
        }
        let b = &bytes[..12];

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47
            && b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A
        {
            return Some(ImageFormat::Png);
        }
        // JPEG: FF D8 FF (SOI marker + start of an APP segment)
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF {
            return Some(ImageFormat::Jpeg);
        }
        // GIF: "GIF87a" or "GIF89a"
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38
            && (b[4] == 0x37 || b[4] == 0x39) && b[5] == 0x61
        {
            return Some(ImageFormat::Gif);
        }
        // WebP: "RIFF" <size:4> "WEBP"
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50
        {
            return Some(ImageFormat::Webp);
        }
        // HEIC/HEIF: "ftyp" box at offset 4, with a HEIF brand at offset 8.
        // Any ISOBMFF file (MP4, MOV, etc.) has "ftyp" at the same offset, so
        // the brand check is what makes this an *image* not a video.
        if b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 {
            let brand = &b[8..12];
            // heic/heix = main HEIF still profiles. mif1/msf1 = HEIF image
            // collection brands. heim/heis = sequence brands seen on iPhones.
            const HEIF_BRANDS: [&[u8; 4]; 6] =
                [b"heic", b"heix", b"heim", b"heis", b"mif1", b"msf1"];
            if HEIF_BRANDS.iter().any(|brand_id| brand == brand_id.as_slice()) {
                return Some(ImageFormat::Heic);
            }
        }
        None
    }

    /// True when this detected format is consistent with the wire-declared
    /// `mime_type`. `image/jpg` is folded into `image/jpeg` for tolerance.
    pub fn matches_mime(self, mime_type: &str) -> bool {
        let mt = mime_type.to_ascii_lowercase();
        match self {
            ImageFormat::Png => mt == "image/png",
            ImageFormat::Jpeg => mt == "image/jpeg" || mt == "image/jpg",
            ImageFormat::Gif => mt == "image/gif",
            ImageFormat::Webp => mt == "image/webp",
            ImageFormat::Heic => mt == "image/heic" || mt == "image/heif",
        }
    }
}

/// Receives an `ImageUploadMessage`, decodes the base64 payload, and writes
/// it into a sandboxed uploads directory. Mirrors Mac's `ImageUploadHandler`:
/// both `imageId` and `filename` are sanitized and the resolved target path is
/// verified to lie inside the uploads root so a malicious phone cannot escape
/// via `../` injection in either field.
pub struct ImageUploadHandler {
    uploads_dir: PathBuf,
}

impl ImageUploadHandler {
    pub fn new(uploads_dir: PathBuf) -> Self {
        Self { uploads_dir }
    }

    /// Production initializer: $XDG_CACHE_HOME/quip/uploads (typically ~/.cache/quip/uploads).
    pub fn default_production() -> Self {
        let dir = directories::ProjectDirs::from("dev", "quip", "quip")
            .map(|p| p.cache_dir().join("uploads"))
            .unwrap_or_else(|| PathBuf::from("/tmp/quip/uploads"));
        Self::new(dir)
    }

    pub fn uploads_dir(&self) -> &Path {
        &self.uploads_dir
    }

    /// Decode + write. Returns the absolute path of the saved file.
    pub fn save(&self, msg: &ImageUploadMessage) -> Result<PathBuf, ImageUploadError> {
        let bytes = BASE64
            .decode(msg.data.as_bytes())
            .map_err(|_| ImageUploadError::InvalidBase64)?;

        // Magic-byte sniff before anything else hits disk. Two checks:
        //   1. Bytes look like an image at all.
        //   2. The detected format is consistent with the declared mimeType.
        // Together these reject "I'm uploading a JPEG" → script.sh and "this
        // is an image (mimeType=image/png)" → arbitrary binary blob.
        let format = ImageFormat::detect(&bytes).ok_or(ImageUploadError::NotAnImage)?;
        if !format.matches_mime(&msg.mime_type) {
            return Err(ImageUploadError::MimeTypeMismatch {
                detected: format,
                declared: msg.mime_type.clone(),
            });
        }

        fs::create_dir_all(&self.uploads_dir).map_err(ImageUploadError::WriteFailed)?;

        let safe_id = sanitize(&msg.image_id);
        let safe_name = sanitize(&msg.filename);
        let target = self.uploads_dir.join(format!("{safe_id}-{safe_name}"));

        // Defense in depth: the resolved target must lie inside the uploads
        // root. PathBuf::join doesn't canonicalize `..`, so a prefix check on
        // the un-resolved path is insufficient. Canonicalize both ends.
        let resolved_root = canonicalize_or(&self.uploads_dir);
        // Canonicalize the parent + append filename, since the target file
        // doesn't exist yet (canonicalize would fail on the full path).
        let parent = target
            .parent()
            .ok_or(ImageUploadError::InvalidPath)?;
        let resolved_parent = canonicalize_or(parent);
        let file_name = target
            .file_name()
            .ok_or(ImageUploadError::InvalidPath)?;
        let resolved_target = resolved_parent.join(file_name);

        if !path_is_inside(&resolved_target, &resolved_root) {
            return Err(ImageUploadError::InvalidPath);
        }

        fs::write(&resolved_target, &bytes).map_err(ImageUploadError::WriteFailed)?;
        Ok(resolved_target)
    }
}

/// Reduce an arbitrary wire string to a safe single filename component.
/// Strip path separators and parent-directory tokens; fall back to "file" if
/// the result is empty.
fn sanitize(component: &str) -> String {
    // Match Swift's NSString.lastPathComponent behavior.
    let last = Path::new(component)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(component);

    let mut filtered: String = last
        .replace('/', "_")
        .replace('\\', "_");

    // Collapse `..` tokens that survived (e.g. "foo..bar" — no separator
    // before `..`, so lastPathComponent leaves it intact). Loop until stable.
    while filtered.contains("..") {
        filtered = filtered.replace("..", "_");
    }

    if filtered.is_empty() {
        "file".to_string()
    } else {
        filtered
    }
}

/// Canonicalize if possible; otherwise return the input unchanged. Used so
/// the sandbox check still works on first run before the dir exists.
fn canonicalize_or(p: &Path) -> PathBuf {
    fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

fn path_is_inside(child: &Path, root: &Path) -> bool {
    let mut child_iter = child.components();
    let root_iter = root.components();
    for r in root_iter {
        match child_iter.next() {
            Some(c) if c == r => continue,
            _ => return false,
        }
    }
    // child must have at least one more component (i.e. not equal to root)
    child_iter.next().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use uuid::Uuid;

    const TINY_PNG_B64: &str =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

    fn temp_root() -> PathBuf {
        let dir = env::temp_dir().join(format!("ImageUploadHandlerTests-{}", Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn msg(image_id: &str, filename: &str, data: &str) -> ImageUploadMessage {
        ImageUploadMessage {
            image_id: image_id.into(),
            window_id: "w1".into(),
            filename: filename.into(),
            mime_type: "image/png".into(),
            data: data.into(),
        }
    }

    #[test]
    fn writes_file_and_returns_absolute_path() {
        let root = temp_root();
        let handler = ImageUploadHandler::new(root.clone());
        let saved = handler.save(&msg("abc-123", "tiny.png", TINY_PNG_B64)).unwrap();

        let resolved_root = fs::canonicalize(&root).unwrap();
        assert!(saved.starts_with(&resolved_root));
        let last = saved.file_name().unwrap().to_string_lossy().to_string();
        assert!(last.contains("abc-123"));
        assert!(last.ends_with("tiny.png"));
        assert!(saved.exists());
        let written = fs::read(&saved).unwrap();
        let expected = BASE64.decode(TINY_PNG_B64).unwrap();
        assert_eq!(written, expected);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn rejects_invalid_base64() {
        let root = temp_root();
        let handler = ImageUploadHandler::new(root.clone());
        let r = handler.save(&msg("bad", "x.png", "!!!not valid!!!"));
        assert!(matches!(r, Err(ImageUploadError::InvalidBase64)));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn sanitizes_filename_traversal() {
        let root = temp_root();
        let handler = ImageUploadHandler::new(root.clone());
        let saved = handler
            .save(&msg("x", "../../evil.png", TINY_PNG_B64))
            .unwrap();
        let resolved_root = fs::canonicalize(&root).unwrap();
        assert!(saved.starts_with(&resolved_root));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn sanitizes_image_id_traversal() {
        let root = temp_root();
        let handler = ImageUploadHandler::new(root.clone());
        let saved = handler
            .save(&msg("../../../../tmp/quip-escape", "evil.png", TINY_PNG_B64))
            .unwrap();
        let resolved_root = fs::canonicalize(&root).unwrap();
        assert!(saved.starts_with(&resolved_root));
        assert!(!Path::new("/tmp/quip-escape-evil.png").exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn dot_dot_in_filename_gets_replaced() {
        let root = temp_root();
        let handler = ImageUploadHandler::new(root.clone());
        // No leading separator, so file_name() leaves it intact —
        // the loop-replace must catch it.
        let saved = handler.save(&msg("x", "foo..bar..png", TINY_PNG_B64)).unwrap();
        let last = saved.file_name().unwrap().to_string_lossy().to_string();
        assert!(!last.contains(".."), "sanitize() failed: {last}");
        let _ = fs::remove_dir_all(&root);
    }

    // ---- Magic-byte / mimeType validation -----------------------------------

    fn msg_with_mime(filename: &str, mime: &str, data: &str) -> ImageUploadMessage {
        ImageUploadMessage {
            image_id: "x".into(),
            window_id: "w1".into(),
            filename: filename.into(),
            mime_type: mime.into(),
            data: data.into(),
        }
    }

    #[test]
    fn rejects_non_image_payload() {
        let root = temp_root();
        let handler = ImageUploadHandler::new(root.clone());
        // 16 zero bytes — base64-decodes successfully but isn't any known
        // image format. Stand-in for "phone uploaded a script / archive /
        // arbitrary binary blob and labelled it image/png."
        let zeros = BASE64.encode([0u8; 16]);
        let r = handler.save(&msg_with_mime("fake.png", "image/png", &zeros));
        assert!(matches!(r, Err(ImageUploadError::NotAnImage)));

        let listing: Vec<_> = fs::read_dir(&root).unwrap().collect();
        assert!(listing.is_empty(), "non-image landed on disk");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn rejects_mime_type_mismatch() {
        let root = temp_root();
        let handler = ImageUploadHandler::new(root.clone());
        // Real PNG bytes, but the wire claims it's a JPEG.
        let r = handler.save(&msg_with_mime("tiny.jpg", "image/jpeg", TINY_PNG_B64));
        match r {
            Err(ImageUploadError::MimeTypeMismatch { detected, declared }) => {
                assert_eq!(detected, ImageFormat::Png);
                assert_eq!(declared, "image/jpeg");
            }
            other => panic!("expected MimeTypeMismatch, got {other:?}"),
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn detect_recognizes_png() {
        let png: &[u8] = &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                           0x00, 0x00, 0x00, 0x0D];
        assert_eq!(ImageFormat::detect(png), Some(ImageFormat::Png));
    }

    #[test]
    fn detect_recognizes_jpeg() {
        let jpeg: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
                            0x49, 0x46, 0x00, 0x01];
        assert_eq!(ImageFormat::detect(jpeg), Some(ImageFormat::Jpeg));
    }

    #[test]
    fn detect_recognizes_gif() {
        assert_eq!(ImageFormat::detect(b"GIF89a000000"), Some(ImageFormat::Gif));
        assert_eq!(ImageFormat::detect(b"GIF87a000000"), Some(ImageFormat::Gif));
    }

    #[test]
    fn detect_recognizes_webp() {
        let webp: &[u8] = &[0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00,
                            0x57, 0x45, 0x42, 0x50];
        assert_eq!(ImageFormat::detect(webp), Some(ImageFormat::Webp));
    }

    #[test]
    fn detect_recognizes_heic() {
        let heic: &[u8] = &[0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
                            0x68, 0x65, 0x69, 0x63];
        assert_eq!(ImageFormat::detect(heic), Some(ImageFormat::Heic));
    }

    #[test]
    fn detect_rejects_mp4() {
        // MP4 also has "ftyp" at offset 4 but a different brand.
        let mp4: &[u8] = &[0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
                           0x6D, 0x70, 0x34, 0x32]; // "mp42"
        assert_eq!(ImageFormat::detect(mp4), None);
    }

    #[test]
    fn detect_rejects_short_input() {
        assert_eq!(ImageFormat::detect(&[0x89, 0x50]), None);
        assert_eq!(ImageFormat::detect(&[]), None);
    }

    #[test]
    fn matches_mime_jpeg_alias() {
        assert!(ImageFormat::Jpeg.matches_mime("image/jpeg"));
        assert!(ImageFormat::Jpeg.matches_mime("image/jpg"));
        assert!(ImageFormat::Jpeg.matches_mime("IMAGE/JPEG"));
        assert!(!ImageFormat::Jpeg.matches_mime("image/png"));
    }

    #[test]
    fn matches_mime_heic_and_heif_interchangeable() {
        assert!(ImageFormat::Heic.matches_mime("image/heic"));
        assert!(ImageFormat::Heic.matches_mime("image/heif"));
    }
}
