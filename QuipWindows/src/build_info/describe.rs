//! The build stamp's one rule, with no crate imports so `build.rs` can
//! include this file (`#[path]`) and stamp the exe with the same function
//! the tests check.

/// `0.1.0 (a52c5e2abcde)`, `0.1.0 (a52c5e2abcde-dirty)` when the tree had
/// uncommitted changes, or `0.1.0` when the build had no git.
pub fn describe(version: &str, sha: Option<&str>, dirty: bool) -> String {
    match sha {
        Some(sha) if dirty => format!("{version} ({sha}-dirty)"),
        Some(sha) => format!("{version} ({sha})"),
        None => version.to_string(),
    }
}
