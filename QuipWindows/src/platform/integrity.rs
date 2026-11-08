//! Spec 5.4 step 2b, pure: may Quip type into a window, judged by the
//! integrity level of the process that owns it?
//!
//! Windows (UIPI) drops input a process sends to a window of a HIGHER
//! integrity level, and the `SendInput` docs say neither its return value
//! nor `GetLastError` shows it. So the shared injector asks before the first
//! input (`WindowBackend::input_access`) and types nothing unless the answer
//! is `Allowed`. A level that cannot be read counts as elevated: a process
//! Quip cannot open with `PROCESS_QUERY_LIMITED_INFORMATION` is, in
//! practice, an administrator's or the system's.
//!
//! The levels are the last sub-authority (RID) of the token's
//! `TokenIntegrityLevel` SID: Low 0x1000, Medium 0x2000, Medium+ 0x2100,
//! High 0x3000, System 0x4000.

pub const LOW_RID: u32 = 0x1000;
pub const MEDIUM_RID: u32 = 0x2000;
pub const HIGH_RID: u32 = 0x3000;
pub const SYSTEM_RID: u32 = 0x4000;

/// Whether input may go to a window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputAccess {
    /// Same or lower integrity than Quip.
    Allowed,
    /// Higher than Quip: Windows would drop the input without saying so.
    Elevated,
    /// Could not be read: treated as `Elevated`.
    Unknown,
}

impl InputAccess {
    pub fn as_str(self) -> &'static str {
        match self {
            InputAccess::Allowed => "allowed",
            InputAccess::Elevated => "elevated",
            InputAccess::Unknown => "unknown",
        }
    }
}

/// `target_rid`: the window owner's level, `None` when it could not be read.
pub fn access(target_rid: Option<u32>, own_rid: u32) -> InputAccess {
    match target_rid {
        None => InputAccess::Unknown,
        Some(t) if t > own_rid => InputAccess::Elevated,
        Some(_) => InputAccess::Allowed,
    }
}

/// One level below `rid`, for the selftest's lowered probe (High -> Medium,
/// Medium -> Low); `None` below Low.
pub fn one_below(rid: u32) -> Option<u32> {
    [SYSTEM_RID, HIGH_RID, MEDIUM_RID, LOW_RID, 0].into_iter().find(|&r| r < rid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn higher_is_elevated() {
        assert_eq!(access(Some(HIGH_RID), MEDIUM_RID), InputAccess::Elevated);
        assert_eq!(access(Some(SYSTEM_RID), HIGH_RID), InputAccess::Elevated);
        assert_eq!(access(Some(MEDIUM_RID + 0x100), MEDIUM_RID), InputAccess::Elevated, "Medium+ over Medium");
        assert_eq!(access(Some(MEDIUM_RID + 1), MEDIUM_RID), InputAccess::Elevated);
    }

    #[test]
    fn same_or_lower_is_allowed() {
        assert_eq!(access(Some(MEDIUM_RID), MEDIUM_RID), InputAccess::Allowed);
        assert_eq!(access(Some(LOW_RID), MEDIUM_RID), InputAccess::Allowed);
        assert_eq!(access(Some(MEDIUM_RID), HIGH_RID), InputAccess::Allowed);
        assert_eq!(access(Some(0), LOW_RID), InputAccess::Allowed);
    }

    #[test]
    fn unreadable_is_unknown() {
        assert_eq!(access(None, MEDIUM_RID), InputAccess::Unknown);
        assert_eq!(access(None, SYSTEM_RID), InputAccess::Unknown);
    }

    #[test]
    fn one_below_steps_down_a_named_level() {
        assert_eq!(one_below(HIGH_RID), Some(MEDIUM_RID));
        assert_eq!(one_below(MEDIUM_RID), Some(LOW_RID));
        assert_eq!(one_below(MEDIUM_RID + 0x100), Some(MEDIUM_RID));
        assert_eq!(one_below(SYSTEM_RID), Some(HIGH_RID));
        assert_eq!(one_below(LOW_RID), Some(0));
        assert_eq!(one_below(0), None);
    }

    #[test]
    fn names_are_log_tokens() {
        // The fake's `access handle=N elevated` line (tools/qa/q91-*.sh) and
        // the probe's `access=` field carry these.
        assert_eq!(InputAccess::Allowed.as_str(), "allowed");
        assert_eq!(InputAccess::Elevated.as_str(), "elevated");
        assert_eq!(InputAccess::Unknown.as_str(), "unknown");
    }
}
