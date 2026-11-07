//! The host's picture of the desktop: tracked windows (with their wire ids,
//! colors and enabled flags), the displays, and the foreground window. Pure
//! data: the poll feeds it platform listings, the server reads snapshots.

use std::collections::{HashMap, HashSet};

use crate::platform::traits::{PlatformDisplay, PlatformWindow, WindowMove, WindowRef};
use crate::protocol::messages::{DisplayState, LayoutUpdate, WindowState};
use crate::protocol::types::{ArrangeLayout, CliKind, TerminalState, WindowFrame};
use crate::services::broadcast::{self, BroadcastCandidate};
use crate::services::geometry::{self, DisplayEntry, DisplayRect};
use crate::services::layout::{self, ArrangeOutcome, PixelRect};
use crate::services::multiline_policy::Shell;
use crate::services::settings::WindowKey;
use crate::services::window_color::ColorAssigner;
use crate::services::window_id::WindowIdTable;

#[derive(Debug, Clone, PartialEq)]
pub struct TrackedWindow {
    pub id: String,
    pub platform: PlatformWindow,
    pub enabled: bool,
    pub color: String,
    pub display_id: Option<String>,
    pub frame: WindowFrame,
    pub on_visible_display: bool,
}

impl TrackedWindow {
    pub fn is_terminal(&self) -> bool {
        self.platform.terminal.is_some()
    }

    /// The shell typing rules use; a non-terminal app counts as unknown, so
    /// multi-line text to it is refused (Enter would submit a chat box).
    pub fn shell(&self) -> Shell {
        self.platform.shell.unwrap_or(Shell::Unknown)
    }

    pub fn key(&self) -> WindowKey {
        key_of(&self.platform)
    }
}

impl BroadcastCandidate for TrackedWindow {
    fn id(&self) -> &str {
        &self.id
    }
    fn is_enabled(&self) -> bool {
        self.enabled
    }
    fn is_terminal(&self) -> bool {
        TrackedWindow::is_terminal(self)
    }
    fn is_target(&self) -> bool {
        false
    }
    fn is_on_visible_screen(&self) -> bool {
        self.on_visible_display
    }
}

/// Spec 5.1: windows have no stable id across restarts, so the enabled choice
/// is stored by exe path + title (app name when the exe is unknown).
pub fn key_of(w: &PlatformWindow) -> WindowKey {
    WindowKey { exe: w.exe_path.clone().unwrap_or_else(|| w.app.clone()), title: w.title.clone() }
}

fn rect(p: PixelRect) -> DisplayRect {
    DisplayRect::new(f64::from(p.x), f64::from(p.y), f64::from(p.width), f64::from(p.height))
}

pub struct AppState {
    ids: WindowIdTable,
    colors: ColorAssigner,
    enabled_by_id: HashMap<String, bool>,
    overrides: HashMap<WindowKey, bool>,
    show_all_apps: bool,
    windows: Vec<TrackedWindow>,
    displays: Vec<PlatformDisplay>,
    foreground: Option<WindowRef>,
    /// The newest listing applied (`update_if_newer`).
    applied_seq: Option<u64>,
}

impl AppState {
    pub fn new(overrides: HashMap<WindowKey, bool>, show_all_apps: bool) -> Self {
        Self {
            ids: WindowIdTable::default(),
            colors: ColorAssigner::default(),
            enabled_by_id: HashMap::new(),
            overrides,
            show_all_apps,
            windows: vec![],
            displays: vec![],
            foreground: None,
            applied_seq: None,
        }
    }

    pub fn set_show_all_apps(&mut self, on: bool) {
        self.show_all_apps = on;
    }

    pub fn displays(&self) -> &[PlatformDisplay] {
        &self.displays
    }

    pub fn windows(&self) -> &[TrackedWindow] {
        &self.windows
    }

    fn display_entries(&self) -> Vec<DisplayEntry> {
        self.displays
            .iter()
            .map(|d| DisplayEntry {
                id: geometry::display_wire_id(&d.device_name),
                is_primary: d.is_primary,
                rect: rect(d.bounds),
            })
            .collect()
    }

    /// Feed one poll's listing, unless a NEWER listing was already applied.
    /// `seq` is taken on the query lane when the listing is read, so it orders
    /// listings by when they were taken; two polls racing back from the lane
    /// can then never put an older desktop on top of a newer one.
    pub fn update_if_newer(
        &mut self,
        seq: u64,
        windows: Vec<PlatformWindow>,
        displays: Vec<PlatformDisplay>,
        foreground: Option<WindowRef>,
    ) -> bool {
        if self.applied_seq.is_some_and(|last| seq <= last) {
            return false;
        }
        self.applied_seq = Some(seq);
        self.update(windows, displays, foreground);
        true
    }

    /// Feed one poll's listing.
    pub fn update(
        &mut self,
        windows: Vec<PlatformWindow>,
        displays: Vec<PlatformDisplay>,
        foreground: Option<WindowRef>,
    ) {
        self.displays = displays;
        self.foreground = foreground;
        let pairs: Vec<(u64, u32)> = windows.iter().map(|w| (w.handle, w.pid)).collect();
        let ids = self.ids.assign(&pairs);
        let entries = self.display_entries();
        let rects: HashMap<String, DisplayRect> = entries.iter().map(|e| (e.id.clone(), e.rect)).collect();
        let mut tracked = Vec::with_capacity(windows.len());
        for (w, id) in windows.into_iter().zip(ids) {
            let enabled = *self
                .enabled_by_id
                .entry(id.clone())
                .or_insert_with(|| self.overrides.get(&key_of(&w)).copied().unwrap_or(false));
            let color = self.colors.color_for(&id);
            let vis = rect(w.visible);
            let display_id = geometry::display_id_for_window(vis, &entries);
            let frame = display_id
                .as_ref()
                .and_then(|d| rects.get(d))
                .map(|d| geometry::normalize(vis, *d))
                .unwrap_or(WindowFrame::ZERO);
            // A minimized window stays in the set (flagged `isMinimized`),
            // even from a backend that reported its parking rect at -32000.
            let on_visible_display = w.is_minimized || geometry::is_on_visible_display(vis, &entries);
            tracked.push(TrackedWindow { id, platform: w, enabled, color, display_id, frame, on_visible_display });
        }
        let live: HashSet<String> = tracked.iter().map(|t| t.id.clone()).collect();
        self.enabled_by_id.retain(|id, _| live.contains(id));
        self.colors.retain(&live);
        self.windows = tracked;
    }

    fn broadcast_set(&self) -> Vec<&TrackedWindow> {
        broadcast::windows_for_broadcast(&self.windows, broadcast::WINDOWS_MIRROR_DESKTOP, self.show_all_apps, None)
    }

    /// A window the phone may act on: only ids in the current broadcast set,
    /// i.e. windows the phone is actually shown. A hidden window (Notepad
    /// with "Show all apps" off) cannot be typed into by a guessed or stale id.
    pub fn find(&self, id: &str) -> Option<&TrackedWindow> {
        self.broadcast_set().into_iter().find(|w| w.id == id)
    }

    /// Any tracked window, shown or not (the fake's console, logs).
    pub fn find_tracked(&self, id: &str) -> Option<&TrackedWindow> {
        self.windows.iter().find(|w| w.id == id)
    }

    pub fn find_tracked_by_handle(&self, handle: u64) -> Option<&TrackedWindow> {
        self.windows.iter().find(|w| w.platform.handle == handle)
    }

    /// `frontmost_changed.windowId`: the foreground window's id when it is in
    /// the broadcast set, else `None` (spec 3.2).
    pub fn frontmost_id(&self) -> Option<String> {
        let fg = self.foreground?;
        self.broadcast_set().into_iter().find(|w| w.platform.window_ref() == fg).map(|w| w.id.clone())
    }

    /// Flip `enabled` (quick action `toggle_enabled`). Returns the key and the
    /// new value so the caller can persist it.
    pub fn toggle_enabled(&mut self, id: &str) -> Option<(WindowKey, bool)> {
        let w = self.windows.iter_mut().find(|w| w.id == id)?;
        w.enabled = !w.enabled;
        let (key, value) = (key_of(&w.platform), w.enabled);
        self.enabled_by_id.insert(id.to_string(), value);
        self.overrides.insert(key.clone(), value);
        Some((key, value))
    }

    /// The `layout_update` for the current state. `monitor` falls back to
    /// "Display 1" like the Mac (`buildDisplayGeometry`).
    pub fn snapshot(&self) -> LayoutUpdate {
        let entries = self.display_entries();
        let rects: Vec<DisplayRect> = entries.iter().map(|e| e.rect).collect();
        let span = geometry::span(&rects);
        let displays: Vec<DisplayState> = self
            .displays
            .iter()
            .zip(&entries)
            .map(|(d, e)| DisplayState {
                id: e.id.clone(),
                name: d.name.clone(),
                is_primary: d.is_primary,
                aspect: geometry::aspect(e.rect).unwrap_or(1.0),
                span_frame: geometry::span_frame(e.rect, span),
            })
            .collect();
        let primary = self.displays.iter().find(|d| d.is_primary).or_else(|| self.displays.first());
        let windows = self
            .broadcast_set()
            .into_iter()
            .map(|w| WindowState {
                id: w.id.clone(),
                name: w.platform.title.clone(),
                app: w.platform.app.clone(),
                folder: None,
                enabled: w.enabled,
                frame: w.frame,
                state: TerminalState::Neutral.as_str().to_string(),
                color: w.color.clone(),
                is_thinking: false,
                claude_mode: None,
                cli_kind: w.is_terminal().then_some(CliKind::Shell),
                target_kind: None,
                display_id: w.display_id.clone(),
                space_id: None,
                is_pinned: false,
                is_minimized: w.platform.is_minimized,
                project: None,
            })
            .collect();
        LayoutUpdate::new(
            primary.map(|p| p.name.clone()).unwrap_or_else(|| "Display 1".to_string()),
            primary.and_then(|p| geometry::aspect(rect(p.bounds))),
            windows,
            Some(displays),
            geometry::aspect(span),
        )
    }

    /// Spec 5.2: the windows the phone shows (the broadcast set), in
    /// broadcast order, tiled on the primary display's work area,
    /// border-compensated. Not only `enabled` ones: under the mirror-desktop
    /// rule nothing starts enabled, so that would arrange nothing. `Err` is
    /// the outcome to report when there is nothing to do.
    pub fn arrange_plan(&self, layout: ArrangeLayout) -> Result<Vec<(String, WindowMove)>, ArrangeOutcome> {
        let enabled: Vec<&TrackedWindow> = self.broadcast_set();
        let Some(primary) = self.displays.iter().find(|d| d.is_primary).or_else(|| self.displays.first()) else {
            return Err(ArrangeOutcome::evaluate(enabled.len(), false, || 0));
        };
        if enabled.is_empty() {
            return Err(ArrangeOutcome::NoWindows);
        }
        let targets = layout::arrange(layout, enabled.len(), primary.work_area);
        Ok(enabled
            .into_iter()
            .zip(targets)
            .map(|(w, t)| {
                (
                    w.id.clone(),
                    WindowMove {
                        window: w.platform.window_ref(),
                        outer: layout::compensate_border(t, w.platform.outer, w.platform.visible),
                        restore_first: w.platform.is_minimized || w.platform.is_maximized,
                    },
                )
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    //! Includes the `FrontmostMatchTests` shape (spec 10.3 `frontmost.rs`):
    //! foreground window -> tracked id, untracked -> `None`.
    use super::*;
    use crate::services::classify::TerminalHost;

    fn display(name: &str, x: i32, primary: bool) -> PlatformDisplay {
        PlatformDisplay {
            device_name: format!(r"\\.\{name}"),
            name: name.to_string(),
            bounds: PixelRect::new(x, 0, 1920, 1080),
            work_area: PixelRect::new(x, 0, 1920, 1040),
            is_primary: primary,
        }
    }

    fn win(handle: u64, terminal: bool, x: i32) -> PlatformWindow {
        let v = PixelRect::new(x, 0, 960, 540);
        PlatformWindow {
            handle,
            pid: handle as u32 + 100,
            title: format!("win {handle}"),
            class_name: "C".into(),
            exe_path: Some(format!("C:\\{handle}.exe")),
            app: if terminal { "Windows Terminal".into() } else { "Notepad".into() },
            terminal: terminal.then_some(TerminalHost::WindowsTerminal),
            shell: terminal.then_some(Shell::Pwsh),
            visible: v,
            outer: PixelRect::new(v.x - 7, v.y, v.width + 14, v.height + 7),
            is_minimized: false,
            is_maximized: false,
        }
    }

    /// The foreground ref of `win(handle, ..)`.
    fn fg(handle: u64) -> Option<WindowRef> {
        Some(WindowRef { handle, pid: handle as u32 + 100 })
    }

    fn state() -> AppState {
        let mut s = AppState::new(HashMap::new(), false);
        s.update(
            vec![win(1, true, 0), win(2, false, 100), win(3, true, 1920 + 960)],
            vec![display("DISPLAY1", 0, true), display("DISPLAY2", 1920, false)],
            fg(1),
        );
        s
    }

    fn relist(s: &mut AppState, fg: Option<WindowRef>) {
        let w: Vec<_> = s.windows().iter().map(|w| w.platform.clone()).collect();
        let d = s.displays().to_vec();
        s.update(w, d, fg);
    }

    #[test]
    fn every_window_starts_disabled_terminals_still_ride_out() {
        // Spec 3.4: `enabled` starts false for every window (as on the Mac);
        // the mirror-desktop rule still sends terminals on a visible display.
        let snap = state().snapshot();
        let apps: Vec<&str> = snap.windows.iter().map(|w| w.app.as_str()).collect();
        assert_eq!(apps, ["Windows Terminal", "Windows Terminal"]);
        assert!(snap.windows.iter().all(|w| !w.enabled && w.cli_kind == Some(CliKind::Shell)));
        assert!(snap.windows.iter().all(|w| w.state == "neutral" && !w.is_thinking && w.folder.is_none()));
    }

    #[test]
    fn show_all_apps_widens_the_set() {
        let mut s = state();
        s.set_show_all_apps(true);
        let snap = s.snapshot();
        assert_eq!(snap.windows.len(), 3);
        let notepad = snap.windows.iter().find(|w| w.app == "Notepad").unwrap();
        assert!(!notepad.enabled);
        assert_eq!(notepad.cli_kind, None);
    }

    #[test]
    fn frames_are_per_display_and_monitor_is_the_primary() {
        let snap = state().snapshot();
        assert_eq!(snap.monitor, "DISPLAY1");
        let second = &snap.windows[1];
        assert!((second.frame.x - 0.5).abs() < 1e-9, "normalized against its own display");
        assert_ne!(second.display_id, snap.windows[0].display_id);
        let displays = snap.displays.unwrap();
        assert!((displays[1].span_frame.x - 0.5).abs() < 1e-9);
        assert!((snap.span_aspect.unwrap() - 3840.0 / 1080.0).abs() < 1e-9);
        assert!((snap.screen_aspect.unwrap() - 1920.0 / 1080.0).abs() < 1e-9);
    }

    #[test]
    fn monitor_does_not_change_with_focus() {
        let mut s = state();
        let a = s.snapshot().monitor;
        relist(&mut s, fg(3));
        assert_eq!(s.snapshot().monitor, a);
    }

    #[test]
    fn frontmost_tracked_and_untracked() {
        let mut s = state();
        assert_eq!(s.frontmost_id(), Some(s.windows()[0].id.clone()));
        relist(&mut s, fg(2));
        assert_eq!(s.frontmost_id(), None, "Notepad is not in the broadcast set");
        relist(&mut s, Some(WindowRef { handle: 1, pid: 5 }));
        assert_eq!(s.frontmost_id(), None, "handle 1 now belongs to another process");
        relist(&mut s, fg(999));
        assert_eq!(s.frontmost_id(), None, "untracked foreground -> windowId null");
        relist(&mut s, None);
        assert_eq!(s.frontmost_id(), None);
    }

    #[test]
    fn toggle_sticks_across_polls_and_is_reapplied_by_key() {
        let mut s = state();
        let id = s.windows()[0].id.clone();
        let (key, v) = s.toggle_enabled(&id).unwrap();
        assert!(v);
        s.toggle_enabled(&id);
        relist(&mut s, None);
        assert!(!s.find(&id).unwrap().enabled);
        s.toggle_enabled(&id);
        relist(&mut s, None);
        assert!(s.find(&id).unwrap().enabled, "the toggle sticks across polls");
        let mut fresh = AppState::new([(key, true)].into_iter().collect(), false);
        fresh.update(vec![win(1, true, 0)], vec![display("DISPLAY1", 0, true)], None);
        assert!(fresh.windows()[0].enabled, "a restart re-applies the choice by key");
        assert!(s.toggle_enabled("nope").is_none());
    }

    #[test]
    fn enabled_app_joins_the_set_and_disabled_terminal_stays() {
        let mut s = state();
        let notepad = s.windows()[1].id.clone();
        s.toggle_enabled(&notepad);
        assert!(s.snapshot().windows.iter().any(|w| w.id == notepad && w.enabled));
        let term = s.windows()[0].id.clone();
        assert!(s.snapshot().windows.iter().any(|w| w.id == term && !w.enabled));
    }

    #[test]
    fn colors_are_stable_per_id() {
        let mut s = state();
        let before: Vec<String> = s.windows().iter().map(|w| w.color.clone()).collect();
        relist(&mut s, None);
        let after: Vec<String> = s.windows().iter().map(|w| w.color.clone()).collect();
        assert_eq!(before, after);
    }

    #[test]
    fn arrange_tiles_the_windows_the_phone_shows_on_the_primary_work_area() {
        let s = state();
        let plan = s.arrange_plan(ArrangeLayout::Horizontal).unwrap();
        assert_eq!(plan.len(), 2, "the two terminals the phone shows, though neither is enabled; not Notepad");
        assert_eq!(plan[0].0, s.windows()[0].id);
        assert_eq!(plan[1].0, s.windows()[2].id);
        assert_eq!(plan[0].1.outer, PixelRect::new(-7, 0, 974, 1047));
        assert_eq!(plan[1].1.outer, PixelRect::new(953, 0, 974, 1047));
        assert_eq!(plan[0].1.window, WindowRef { handle: 1, pid: 101 });
    }

    #[test]
    fn arrange_includes_an_enabled_app_and_show_all_apps() {
        let mut s = state();
        let notepad = s.windows()[1].id.clone();
        s.toggle_enabled(&notepad);
        assert_eq!(s.arrange_plan(ArrangeLayout::Vertical).unwrap().len(), 3);
        let mut s = state();
        s.set_show_all_apps(true);
        assert_eq!(s.arrange_plan(ArrangeLayout::Vertical).unwrap().len(), 3);
    }

    #[test]
    fn arrange_without_windows_or_displays() {
        let mut s = AppState::new(HashMap::new(), false);
        s.update(vec![win(2, false, 0)], vec![display("DISPLAY1", 0, true)], None);
        assert_eq!(s.arrange_plan(ArrangeLayout::Vertical), Err(ArrangeOutcome::NoWindows), "Notepad is not shown");
        let mut s = AppState::new(HashMap::new(), false);
        s.update(vec![win(1, true, 0)], vec![], None);
        let id = s.windows()[0].id.clone();
        s.toggle_enabled(&id);
        assert_eq!(s.arrange_plan(ArrangeLayout::Vertical), Err(ArrangeOutcome::NoDisplay));
    }

    #[test]
    fn minimized_windows_stay_in_the_set_are_flagged_and_restored_first() {
        let mut s = AppState::new(HashMap::new(), false);
        let mut w = win(1, true, 0);
        w.is_minimized = true;
        s.update(vec![w], vec![display("DISPLAY1", 0, true)], None);
        let snap = s.snapshot();
        assert_eq!(snap.windows.len(), 1, "a minimized terminal is still shown");
        assert!(snap.windows[0].is_minimized);
        assert!(snap.windows[0].frame.width > 0.0, "with its restored frame");
        assert!(s.arrange_plan(ArrangeLayout::Vertical).unwrap()[0].1.restore_first);
    }

    #[test]
    fn a_minimized_window_reported_at_the_parking_rect_is_still_shown() {
        // A backend that wrongly used GetWindowRect (-32000, -32000) for a
        // minimized window must not make it vanish from the phone.
        let mut s = AppState::new(HashMap::new(), false);
        let mut term = win(1, true, -32000);
        term.visible = PixelRect::new(-32000, -32000, 160, 28);
        term.is_minimized = true;
        let mut app = win(2, false, -32000);
        app.visible = term.visible;
        app.is_minimized = true;
        s.update(vec![term, app], vec![display("DISPLAY1", 0, true)], None);
        let id2 = s.windows()[1].id.clone();
        s.toggle_enabled(&id2);
        let snap = s.snapshot();
        assert_eq!(snap.windows.len(), 2, "minimized terminal and minimized enabled app both stay");
        assert!(snap.windows.iter().all(|w| w.is_minimized));
    }

    #[test]
    fn find_only_reaches_windows_the_phone_is_shown() {
        let mut s = state();
        let notepad = s.windows()[1].id.clone();
        assert!(s.find(&notepad).is_none(), "Notepad is tracked but not shown");
        assert_eq!(s.find_tracked(&notepad).map(|w| w.platform.handle), Some(2));
        assert_eq!(s.find_tracked_by_handle(2).map(|w| w.id.clone()), Some(notepad.clone()));
        assert!(s.find_tracked_by_handle(99).is_none());
        s.set_show_all_apps(true);
        assert!(s.find(&notepad).is_some());
    }

    #[test]
    fn an_older_listing_never_replaces_a_newer_one() {
        let mut s = AppState::new(HashMap::new(), false);
        let d = vec![display("DISPLAY1", 0, true)];
        assert!(s.update_if_newer(2, vec![win(1, true, 0), win(3, true, 0)], d.clone(), None));
        assert!(!s.update_if_newer(1, vec![win(1, true, 0)], d.clone(), None), "older: dropped");
        assert_eq!(s.windows().len(), 2);
        assert!(!s.update_if_newer(2, vec![], d.clone(), None), "same listing twice: dropped");
        assert!(s.update_if_newer(3, vec![win(1, true, 0)], d, None));
        assert_eq!(s.windows().len(), 1);
    }

    #[test]
    fn a_disabled_terminal_off_every_display_is_not_sent() {
        let mut s = AppState::new(HashMap::new(), false);
        s.update(vec![win(1, true, 0), win(2, true, 5000)], vec![display("DISPLAY1", 0, true)], None);
        let ids: Vec<String> = s.snapshot().windows.iter().map(|w| w.id.clone()).collect();
        assert_eq!(ids, [s.windows()[0].id.clone()]);
        assert_eq!(BroadcastCandidate::id(&s.windows()[1]), s.windows()[1].id);
    }
}
