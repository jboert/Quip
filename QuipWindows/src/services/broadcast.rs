//! Which windows ride out in `layout_update`: a port of
//! `WindowManager.windowsForBroadcast` (`QuipMac/Services/WindowManager.swift`),
//! all four branches (QA pair, mirror all apps, mirror desktop, default).
//!
//! What the Windows host passes (spec 3.4, "Broadcast set"):
//! `mirror_desktop = true` (every terminal on a visible display, plus every
//! enabled window) and `mirror_all_apps = show_all_apps`. A deliberate
//! difference from the Mac default (mirror off): nothing starts enabled and
//! Windows has no window list to enable things in, so mirror-off would show
//! an empty grid after pairing.

/// The fields the filter reads (`ManagedWindow` on the Mac).
pub trait BroadcastCandidate {
    fn id(&self) -> &str;
    fn is_enabled(&self) -> bool;
    fn is_terminal(&self) -> bool;
    /// QA-mode target (Simulator). Always false on Windows.
    fn is_target(&self) -> bool;
    fn is_on_visible_screen(&self) -> bool;
}

pub const WINDOWS_MIRROR_DESKTOP: bool = true;

pub fn windows_for_broadcast<'a, W: BroadcastCandidate>(
    all: &'a [W],
    mirror_desktop: bool,
    mirror_all_apps: bool,
    qa_pair: Option<(&str, &str)>,
) -> Vec<&'a W> {
    if let Some((a, b)) = qa_pair {
        return all.iter().filter(|w| w.id() == a || w.id() == b).collect();
    }
    if mirror_all_apps {
        return all.iter().filter(|w| w.is_on_visible_screen() || w.is_enabled()).collect();
    }
    if mirror_desktop {
        return all
            .iter()
            .filter(|w| ((w.is_terminal() || w.is_target()) && w.is_on_visible_screen()) || w.is_enabled())
            .collect();
    }
    all.iter().filter(|w| w.is_enabled() || (w.is_target() && w.is_on_visible_screen())).collect()
}

#[cfg(test)]
mod tests {
    //! `Shared/Tests/MirrorDesktopFilterTests.swift` (filter cases).
    #![allow(non_snake_case)]
    use super::*;
    use std::collections::HashSet;

    #[derive(Clone)]
    struct W {
        id: &'static str,
        kind: &'static str,
        enabled: bool,
        visible: bool,
    }
    impl BroadcastCandidate for W {
        fn id(&self) -> &str {
            self.id
        }
        fn is_enabled(&self) -> bool {
            self.enabled
        }
        fn is_terminal(&self) -> bool {
            self.kind == "term"
        }
        fn is_target(&self) -> bool {
            self.kind == "sim"
        }
        fn is_on_visible_screen(&self) -> bool {
            self.visible
        }
    }
    fn mw(id: &'static str, kind: &'static str, enabled: bool) -> W {
        W { id, kind, enabled, visible: true }
    }
    fn off(mut w: W) -> W {
        w.visible = false;
        w
    }
    fn ids(v: Vec<&W>) -> HashSet<&'static str> {
        v.into_iter().map(|w| w.id).collect()
    }
    fn set(s: &[&'static str]) -> HashSet<&'static str> {
        s.iter().copied().collect()
    }

    #[test]
    fn testMirrorOffShowsOnlyEnabledWindows() {
        let all = [mw("a", "term", true), mw("b", "term", false), mw("c", "app", true)];
        assert_eq!(ids(windows_for_broadcast(&all, false, false, None)), set(&["a", "c"]));
    }

    #[test]
    fn testMirrorOnShowsAllTerminalsPlusEnabledNonTerminals() {
        let all = [
            mw("a", "term", true),
            mw("b", "term", false),
            mw("c", "term", false),
            mw("d", "app", false),
            mw("e", "app", true),
        ];
        assert_eq!(ids(windows_for_broadcast(&all, true, false, None)), set(&["a", "b", "c", "e"]));
    }

    #[test]
    fn testMirrorOnWithNoTerminalsStillShowsEnabledNonTerminals() {
        let all = [mw("x", "app", true)];
        assert_eq!(ids(windows_for_broadcast(&all, true, false, None)), set(&["x"]));
    }

    #[test]
    fn testMirrorOnDropsOffScreenDisabledTerminals() {
        let all = [mw("a", "term", true), mw("b", "term", false), off(mw("c", "term", false))];
        assert_eq!(ids(windows_for_broadcast(&all, true, false, None)), set(&["a", "b"]));
    }

    #[test]
    fn testMirrorOnKeepsOffScreenEnabledWindows() {
        let all = [off(mw("browser", "app", true)), off(mw("term", "term", false))];
        assert_eq!(ids(windows_for_broadcast(&all, true, false, None)), set(&["browser"]));
    }

    #[test]
    fn testMirrorOffIgnoresVisibilityFlag() {
        let all = [off(mw("a", "term", true)), mw("b", "term", false)];
        assert_eq!(ids(windows_for_broadcast(&all, false, false, None)), set(&["a"]));
    }

    #[test]
    fn testMirrorOffIncludesVisibleTargetsForQADiscoverability() {
        let all = [mw("sim", "sim", false), mw("term", "term", false)];
        assert_eq!(ids(windows_for_broadcast(&all, false, false, None)), set(&["sim"]));
    }

    #[test]
    fn testMirrorOffOffscreenDisabledTargetStillFiltered() {
        let all = [off(mw("sim", "sim", false))];
        assert!(windows_for_broadcast(&all, false, false, None).is_empty());
    }

    #[test]
    fn testQAPairOverridesEnabledAndMirror() {
        let all =
            [mw("sim", "sim", false), mw("term", "term", false), mw("other", "term", true), mw("browser", "app", true)];
        assert_eq!(ids(windows_for_broadcast(&all, false, false, Some(("sim", "term")))), set(&["sim", "term"]));
    }

    #[test]
    fn testQAPairWithMirrorOnStillFiltersToTwo() {
        let all = [mw("sim", "sim", false), mw("term", "term", false), mw("otherTerm", "term", false)];
        assert_eq!(ids(windows_for_broadcast(&all, true, false, Some(("sim", "term")))), set(&["sim", "term"]));
    }

    #[test]
    fn testQAPairNilFallsBackToCurrentBehavior() {
        let all = [mw("a", "term", true), mw("b", "term", false)];
        assert_eq!(ids(windows_for_broadcast(&all, false, false, None)), set(&["a"]));
    }

    #[test]
    fn testQAPairWithMissingIdReturnsOnlyExistingHalf() {
        let all = [mw("sim", "sim", false)];
        assert_eq!(ids(windows_for_broadcast(&all, false, false, Some(("sim", "termGone")))), set(&["sim"]));
    }

    #[test]
    fn testMirrorAllAppsIncludesNonTerminalWindows() {
        let all = [mw("term", "term", false), mw("web", "app", false), mw("chat", "app", false)];
        assert_eq!(ids(windows_for_broadcast(&all, false, true, None)), set(&["term", "web", "chat"]));
    }

    #[test]
    fn testMirrorAllAppsStillHidesOffscreenWindowsUnlessEnabled() {
        let all = [off(mw("gone", "app", false)), off(mw("goneButEnabled", "app", true)), mw("here", "app", false)];
        assert_eq!(ids(windows_for_broadcast(&all, false, true, None)), set(&["goneButEnabled", "here"]));
    }

    #[test]
    fn testMirrorAllAppsIsStrictlyWiderThanMirrorDesktop() {
        let all = [
            mw("term", "term", false),
            mw("web", "app", false),
            mw("sim", "sim", false),
            off(mw("offscreenEnabled", "term", true)),
        ];
        let narrow = ids(windows_for_broadcast(&all, true, false, None));
        let wide = ids(windows_for_broadcast(&all, true, true, None));
        assert!(narrow.is_subset(&wide));
        assert!(wide.contains("web"));
    }

    #[test]
    fn testMirrorAllAppsStillYieldsToAQAPair() {
        let all = [mw("sim", "sim", false), mw("term", "term", false), mw("web", "app", false)];
        assert_eq!(ids(windows_for_broadcast(&all, true, true, Some(("sim", "term")))), set(&["sim", "term"]));
    }

    #[test]
    fn order_is_preserved() {
        let all = [mw("c", "term", true), mw("a", "term", true), mw("b", "term", true)];
        let order: Vec<&str> = windows_for_broadcast(&all, true, false, None).into_iter().map(|w| w.id).collect();
        assert_eq!(order, ["c", "a", "b"]);
    }

    // --- Windows defaults ---

    #[test]
    fn windows_default_shows_terminals_and_hides_disabled_apps() {
        let all = [mw("t", "term", true), mw("t-off", "term", false), mw("app", "app", false)];
        assert_eq!(
            ids(windows_for_broadcast(&all, WINDOWS_MIRROR_DESKTOP, false, None)),
            set(&["t", "t-off"]),
            "terminals ride out enabled or not"
        );
        assert_eq!(
            ids(windows_for_broadcast(&all, WINDOWS_MIRROR_DESKTOP, true, None)),
            set(&["t", "t-off", "app"]),
            "Show all apps widens to every listed window"
        );
    }
}
