use std::fs;
use std::path::{Path, PathBuf};

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};

use crate::protocol::messages::ImageUploadMessage;

#[derive(Debug)]
pub enum ImageUploadError {
    InvalidBase64,
    InvalidPath,
    WriteFailed(std::io::Error),
}

impl std::fmt::Display for ImageUploadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidBase64 => write!(f, "invalid base64 image data"),
            Self::InvalidPath => write!(f, "image path failed sandbox check"),
            Self::WriteFailed(e) => write!(f, "write failed: {e}"),
        }
    }
}

impl std::error::Error for ImageUploadError {}

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
}
