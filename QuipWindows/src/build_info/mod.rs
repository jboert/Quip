//! The build stamp (spec 9): `Quip --version`, the tray tooltip, the first
//! `websocket.log` line of each start and the `--selftest` header all show
//! `Quip for Windows <BUILD>`, so a log or a report names the exact build.
//!
//! `build.rs` sets `QUIP_BUILD` with `describe` (shared through `#[path]`)
//! and `QUIP_GIT_SHA` (12 hex chars) when the build had git.

mod describe;

pub use describe::describe;

/// `<version> (<sha>[-dirty])`, or the version alone without git.
pub const BUILD: &str = env!("QUIP_BUILD");

/// The 12-char commit, when the build had git.
pub const GIT_SHA: Option<&str> = option_env!("QUIP_GIT_SHA");

/// `Quip for Windows <BUILD>`.
pub fn product_line() -> String {
    format!("Quip for Windows {BUILD}")
}

/// The commit a `describe` string names, without `-dirty`; `None` for a
/// build without git.
pub fn sha_of(build: &str) -> Option<&str> {
    let inner = build.split_once(" (")?.1.strip_suffix(')')?;
    let sha = inner.strip_suffix("-dirty").unwrap_or(inner);
    (!sha.is_empty() && sha.chars().all(|c| c.is_ascii_hexdigit())).then_some(sha)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describe_names_the_commit() {
        assert_eq!(describe("0.1.0", Some("a52c5e2abcde"), false), "0.1.0 (a52c5e2abcde)");
    }

    #[test]
    fn describe_marks_a_dirty_tree_after_the_sha() {
        assert_eq!(describe("0.1.0", Some("a52c5e2abcde"), true), "0.1.0 (a52c5e2abcde-dirty)");
    }

    #[test]
    fn describe_without_git_is_the_version_alone() {
        assert_eq!(describe("0.1.0", None, false), "0.1.0");
        assert_eq!(describe("0.1.0", None, true), "0.1.0", "no git, so nothing can be dirty");
    }

    #[test]
    fn sha_of_reads_back_what_describe_wrote() {
        assert_eq!(sha_of(&describe("0.1.0", Some("a52c5e2abcde"), false)), Some("a52c5e2abcde"));
        assert_eq!(sha_of(&describe("0.1.0", Some("a52c5e2abcde"), true)), Some("a52c5e2abcde"));
        assert_eq!(sha_of("0.1.0"), None);
        assert_eq!(sha_of("0.1.0 ()"), None, "an empty sha is no sha");
        assert_eq!(sha_of("0.1.0 (not hex!)"), None);
    }

    #[test]
    fn this_build_is_stamped_with_its_own_version() {
        assert!(BUILD.starts_with(env!("CARGO_PKG_VERSION")), "{BUILD}");
        assert_eq!(sha_of(BUILD), GIT_SHA, "{BUILD}");
        assert_eq!(product_line(), format!("Quip for Windows {BUILD}"));
    }
}
