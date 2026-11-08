//! In-memory platform for the Mac: the integration tests and
//! `--fake-platform` (spec 10.6) run the real server against it.
//!
//! It records every call, keeps a per-window stream of what was typed, and can
//! be told to misbehave the ways Windows does: refuse focus, report which
//! focus step worked, refuse a move (elevated window), hold a minimum size,
//! land a move scaled (another monitor's DPI), report no border until a
//! minimized window is restored (DWM), block while typing
//! (the hang guard), steal focus between inputs, insert only part of a batch
//! (UIPI), run at a higher integrity level (`set_input_access`), reuse a
//! closed window's handle for a new process, or start a
//! program (`python`) inside a shell.
//!
//! Input lands like `SendInput`: in whatever window is in front. The fake's
//! own "is the target in front" check can be switched off
//! (`set_input_guard(false)`) so tests prove the INJECTOR's check is the one
//! that keeps text out of the wrong window.
//!
//! `set_echo(true)` (`--fake-platform`) prints one stdout line per action it
//! performs, counts only, never text, so a tap on the phone can be verified.
//!
//! Windows come from a fixture (`tools/fake-windows/fixture.json`) and are
//! classified with the real `classify`, so the fake exercises that too.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use serde::Deserialize;

use super::traits::{
    FocusStep, InputAccess, InputBackend, PlatformDisplay, PlatformError, PlatformResult, PlatformWindow,
    WindowBackend, WindowMove, WindowRects, WindowRef,
};
use crate::services::classify;
use crate::services::keys::KeyChord;
use crate::services::layout::PixelRect;
use crate::services::multiline_policy::Shell;

/// One recorded call.
#[derive(Debug, Clone, PartialEq)]
pub enum FakeCall {
    Focus {
        handle: u64,
        step: FocusStep,
    },
    FocusRefused {
        handle: u64,
    },
    TypeText {
        handle: u64,
        text: String,
    },
    Key {
        handle: u64,
        chord: KeyChord,
    },
    /// The injector asked the window's integrity level (spec 5.4 step 2b).
    InputAccess {
        handle: u64,
    },
    Restore {
        handle: u64,
    },
    Move {
        handle: u64,
        outer: PixelRect,
    },
    MoveRefused {
        handle: u64,
    },
    Minimize {
        handle: u64,
    },
    Close {
        handle: u64,
    },
}

/// What a window received, in order.
#[derive(Debug, Clone, PartialEq)]
pub enum Typed {
    Text(String),
    Key(KeyChord),
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq)]
pub struct FixtureRect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl From<FixtureRect> for PixelRect {
    fn from(r: FixtureRect) -> Self {
        PixelRect::new(r.x, r.y, r.width, r.height)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FixtureDisplay {
    pub device_name: String,
    pub name: String,
    pub bounds: FixtureRect,
    pub work_area: FixtureRect,
    #[serde(default)]
    pub is_primary: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FixtureWindow {
    pub handle: u64,
    pub pid: u32,
    pub title: String,
    pub class_name: String,
    #[serde(default)]
    pub exe_path: Option<String>,
    #[serde(default)]
    pub product_name: Option<String>,
    /// Innermost shell of each attached console (`classify::resolve_shell`).
    #[serde(default)]
    pub shells: Vec<String>,
    pub visible: FixtureRect,
    /// Invisible resize border, px (left, right, bottom; Windows 10/11 has 0
    /// on top). Default 7.
    #[serde(default = "default_border")]
    pub border: i32,
    #[serde(default)]
    pub is_minimized: bool,
}

fn default_border() -> i32 {
    7
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fixture {
    #[serde(default)]
    pub display_name: Option<String>,
    pub displays: Vec<FixtureDisplay>,
    pub windows: Vec<FixtureWindow>,
    #[serde(default)]
    pub foreground: Option<u64>,
}

impl Fixture {
    pub fn parse(json: &str) -> Result<Fixture, String> {
        let f: Fixture = serde_json::from_str(json).map_err(|e| format!("fixture does not parse: {e}"))?;
        if f.displays.iter().filter(|d| d.is_primary).count() != 1 {
            return Err("fixture needs exactly one primary display".into());
        }
        let mut seen = HashSet::new();
        for w in &f.windows {
            if !seen.insert(w.handle) {
                return Err(format!("duplicate window handle {}", w.handle));
            }
        }
        Ok(f)
    }
}

/// Build a `PlatformWindow` the way the Win32 lister will: classified, with
/// the outer rect grown by the border.
pub fn window_from_fixture(w: &FixtureWindow) -> PlatformWindow {
    let c = classify::classify(&w.class_name, w.exe_path.as_deref(), w.product_name.as_deref(), &w.shells);
    let v: PixelRect = w.visible.into();
    PlatformWindow {
        handle: w.handle,
        pid: w.pid,
        title: w.title.clone(),
        class_name: w.class_name.clone(),
        exe_path: w.exe_path.clone(),
        app: c.app,
        terminal: c.terminal,
        shell: c.shell,
        visible: v,
        outer: PixelRect::new(v.x - w.border, v.y, v.width + 2 * w.border, v.height + w.border),
        is_minimized: w.is_minimized,
        is_maximized: false,
    }
}

pub fn display_from_fixture(d: &FixtureDisplay) -> PlatformDisplay {
    PlatformDisplay {
        device_name: d.device_name.clone(),
        name: d.name.clone(),
        bounds: d.bounds.into(),
        work_area: d.work_area.into(),
        is_primary: d.is_primary,
    }
}

#[derive(Debug, Default)]
struct State {
    windows: Vec<PlatformWindow>,
    displays: Vec<PlatformDisplay>,
    foreground: Option<u64>,
    calls: Vec<FakeCall>,
    typed: HashMap<u64, Vec<Typed>>,
    refuse_focus: HashSet<u64>,
    focus_step: Option<FocusStep>,
    refuse_move: HashSet<u64>,
    /// Border (px) a window gets once restored; until then it reports none.
    border_after_restore: HashMap<u64, i32>,
    /// The next move of the window lands with its size scaled by this percent.
    rescale_once: HashMap<u64, i32>,
    /// Smallest outer size the window accepts (`WM_GETMINMAXINFO`).
    min_size: HashMap<u64, (i32, i32)>,
    block_typing: Option<Duration>,
    /// After this many inputs (batches + chords), focus jumps to the window.
    steal_focus: Option<(usize, u64)>,
    inputs_done: usize,
    fail_listing: bool,
    /// The programs running in each window's consoles, innermost first
    /// (`classify::resolve_shell`), when they differ from the listing.
    running: HashMap<u64, Vec<String>>,
    /// `true` = the fake does NOT check the target is in front before input.
    no_input_guard: bool,
    /// At most this many units per batch / events per chord get in.
    input_limit: Option<usize>,
    /// `input_access` answers per window (default `Allowed`).
    input_access: HashMap<u64, InputAccess>,
    /// `input_access` fails with this for the window.
    input_access_error: HashMap<u64, PlatformError>,
    /// Input-lane calls panic (kills the lane: "input thread stopped").
    panic_input: bool,
    echo: bool,
    /// Every action line, printed to stdout too when `echo`.
    actions: Vec<String>,
}

/// Cheap to clone; clones share state.
#[derive(Clone, Default)]
pub struct FakePlatform {
    state: Arc<Mutex<State>>,
}

impl FakePlatform {
    pub fn new(windows: Vec<PlatformWindow>, displays: Vec<PlatformDisplay>) -> Self {
        let p = FakePlatform::default();
        {
            let mut s = p.lock();
            s.windows = windows;
            s.displays = displays;
        }
        p
    }

    pub fn from_fixture(f: &Fixture) -> Self {
        let p = Self::new(
            f.windows.iter().map(window_from_fixture).collect(),
            f.displays.iter().map(display_from_fixture).collect(),
        );
        {
            let mut s = p.lock();
            s.foreground = f.foreground;
            for w in &f.windows {
                s.running.insert(w.handle, w.shells.clone());
            }
        }
        p
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    // --- scripting ---

    pub fn add_window(&self, w: PlatformWindow) {
        self.lock().windows.push(w);
    }

    pub fn remove_window(&self, handle: u64) -> bool {
        let mut s = self.lock();
        let before = s.windows.len();
        s.windows.retain(|w| w.handle != handle);
        if s.foreground == Some(handle) {
            s.foreground = None;
        }
        s.windows.len() != before
    }

    pub fn move_window(&self, handle: u64, visible: PixelRect) -> bool {
        let mut s = self.lock();
        match s.windows.iter_mut().find(|w| w.handle == handle) {
            Some(w) => {
                let (dl, dt) = (visible.x - w.visible.x, visible.y - w.visible.y);
                let (dw, dh) = (visible.width - w.visible.width, visible.height - w.visible.height);
                w.visible = visible;
                w.outer = PixelRect::new(w.outer.x + dl, w.outer.y + dt, w.outer.width + dw, w.outer.height + dh);
                true
            }
            None => false,
        }
    }

    pub fn set_title(&self, handle: u64, title: &str) {
        if let Some(w) = self.lock().windows.iter_mut().find(|w| w.handle == handle) {
            w.title = title.to_string();
        }
    }

    pub fn set_foreground(&self, handle: Option<u64>) {
        self.lock().foreground = handle;
    }

    pub fn set_refuse_focus(&self, handle: u64, refuse: bool) {
        let mut s = self.lock();
        if refuse {
            s.refuse_focus.insert(handle);
        } else {
            s.refuse_focus.remove(&handle);
        }
    }

    /// The step a successful focus reports (default `SetForeground`).
    pub fn set_focus_step(&self, step: FocusStep) {
        self.lock().focus_step = Some(step);
    }

    pub fn set_refuse_move(&self, handle: u64, refuse: bool) {
        let mut s = self.lock();
        if refuse {
            s.refuse_move.insert(handle);
        } else {
            s.refuse_move.remove(&handle);
        }
    }

    /// The window reports no invisible border (outer = visible) until it is
    /// restored, then `px` on the left, right and bottom: a minimized window
    /// has no DWM bounds, so its border is known only after restore.
    pub fn set_border_after_restore(&self, handle: u64, px: i32) {
        let mut s = self.lock();
        if let Some(w) = s.windows.iter_mut().find(|w| w.handle == handle) {
            w.outer = w.visible;
        }
        s.border_after_restore.insert(handle, px);
    }

    /// The window's next move lands with its width and height scaled by
    /// `percent` (a move onto a monitor with another DPI).
    pub fn set_rescale_once(&self, handle: u64, percent: i32) {
        self.lock().rescale_once.insert(handle, percent);
    }

    /// The window keeps an outer size of at least `w` x `h`.
    pub fn set_min_size(&self, handle: u64, w: i32, h: i32) {
        self.lock().min_size.insert(handle, (w, h));
    }

    pub fn set_maximized(&self, handle: u64, on: bool) {
        if let Some(w) = self.lock().windows.iter_mut().find(|w| w.handle == handle) {
            w.is_maximized = on;
            if on {
                w.is_minimized = false;
            }
        }
    }

    pub fn set_minimized(&self, handle: u64, on: bool) {
        if let Some(w) = self.lock().windows.iter_mut().find(|w| w.handle == handle) {
            w.is_minimized = on;
        }
    }

    pub fn set_block_typing(&self, d: Option<Duration>) {
        self.lock().block_typing = d;
    }

    /// After `after_inputs` more inputs (typing batches or chords) land,
    /// the foreground jumps to `to`, as if the user clicked it.
    pub fn set_steal_focus(&self, after_inputs: usize, to: u64) {
        let mut s = self.lock();
        s.steal_focus = Some((after_inputs, to));
        s.inputs_done = 0;
    }

    /// `false`: the fake types into whatever is in front without checking it
    /// is the target, exactly like `SendInput`.
    pub fn set_input_guard(&self, on: bool) {
        self.lock().no_input_guard = !on;
    }

    /// Windows inserts at most `n` units per batch (and `n` events per chord);
    /// `None` lifts it. `Some(0)` is UIPI blocking everything.
    pub fn set_input_limit(&self, n: Option<usize>) {
        self.lock().input_limit = n;
    }

    /// What `input_access` answers for the window (an elevated window:
    /// `Elevated`). The fake's own typing is NOT stopped by it: only the
    /// injector's check keeps the input out, as on Windows, where UIPI drops
    /// it silently.
    pub fn set_input_access(&self, handle: u64, access: InputAccess) {
        self.lock().input_access.insert(handle, access);
    }

    /// `input_access` fails with `err` for the window (`None` clears it).
    pub fn set_input_access_error(&self, handle: u64, err: Option<PlatformError>) {
        let mut s = self.lock();
        match err {
            Some(e) => s.input_access_error.insert(handle, e),
            None => s.input_access_error.remove(&handle),
        };
    }

    /// Start (or end) a program in the window's console: `["pwsh.exe",
    /// "python.exe"]` is pwsh running python. The listing is NOT updated:
    /// only a fresh `current_shell` sees it, as when the user starts python
    /// a moment before tapping send.
    pub fn set_running(&self, handle: u64, programs: &[&str]) {
        self.lock().running.insert(handle, programs.iter().map(|p| p.to_string()).collect());
    }

    /// The window closes and Windows gives its handle to a new window in
    /// process `pid` (HWND reuse).
    pub fn reuse_handle(&self, handle: u64, pid: u32, title: &str) {
        let mut s = self.lock();
        if let Some(w) = s.windows.iter_mut().find(|w| w.handle == handle) {
            w.pid = pid;
            w.title = title.to_string();
        }
        s.running.remove(&handle);
    }

    pub fn set_panic_input(&self, on: bool) {
        self.lock().panic_input = on;
    }

    pub fn set_echo(&self, on: bool) {
        self.lock().echo = on;
    }

    pub fn set_fail_listing(&self, fail: bool) {
        self.lock().fail_listing = fail;
    }

    // --- inspection ---

    pub fn calls(&self) -> Vec<FakeCall> {
        self.lock().calls.clone()
    }

    pub fn clear_calls(&self) {
        let mut s = self.lock();
        s.calls.clear();
        s.typed.clear();
    }

    pub fn typed(&self, handle: u64) -> Vec<Typed> {
        self.lock().typed.get(&handle).cloned().unwrap_or_default()
    }

    pub fn windows(&self) -> Vec<PlatformWindow> {
        self.lock().windows.clone()
    }

    pub fn foreground(&self) -> Option<u64> {
        self.lock().foreground
    }

    /// The window `r` names, if that handle is still owned by that pid.
    fn owned(s: &State, r: WindowRef) -> bool {
        s.windows.iter().any(|w| w.handle == r.handle && w.pid == r.pid)
    }

    fn say(s: &mut State, line: String) {
        if s.echo {
            println!("fake: {line}");
        }
        s.actions.push(line);
    }

    /// The action lines so far (what `--fake-platform` prints).
    pub fn actions(&self) -> Vec<String> {
        self.lock().actions.clone()
    }

    fn check_panic(&self) {
        let p = self.lock().panic_input;
        if p {
            panic!("fake input lane panic (set_panic_input)");
        }
    }

    /// Count one landed input; steal focus when the script says so.
    fn after_input(s: &mut State) {
        s.inputs_done += 1;
        if let Some((after, to)) = s.steal_focus {
            if s.inputs_done >= after {
                s.foreground = Some(to);
                s.steal_focus = None;
                Self::say(s, format!("focus stolen by handle={to}"));
            }
        }
    }

    /// Where input goes: the foreground window. `Err` when the guard is on
    /// and that is not the target.
    fn input_target(s: &State, r: WindowRef) -> PlatformResult<Option<u64>> {
        if !Self::owned(s, r) {
            return Err(PlatformError::WindowGone);
        }
        if !s.no_input_guard && s.foreground != Some(r.handle) {
            return Err(PlatformError::FocusLost { after_chars: 0 });
        }
        Ok(s.foreground)
    }
}

impl WindowBackend for FakePlatform {
    fn list_windows(&self) -> PlatformResult<Vec<PlatformWindow>> {
        let s = self.lock();
        if s.fail_listing {
            return Err(PlatformError::Failed("fake listing failure".into()));
        }
        Ok(s.windows.clone())
    }

    fn list_displays(&self) -> PlatformResult<Vec<PlatformDisplay>> {
        Ok(self.lock().displays.clone())
    }

    fn foreground_window(&self) -> PlatformResult<Option<WindowRef>> {
        let s = self.lock();
        Ok(s.foreground.map(|h| WindowRef {
            handle: h,
            pid: s.windows.iter().find(|w| w.handle == h).map(|w| w.pid).unwrap_or(0),
        }))
    }

    fn current_shell(&self, r: WindowRef) -> PlatformResult<Option<Shell>> {
        let s = self.lock();
        let Some(w) = s.windows.iter().find(|w| w.handle == r.handle && w.pid == r.pid) else {
            return Err(PlatformError::WindowGone);
        };
        if w.terminal.is_none() {
            return Ok(None);
        }
        Ok(Some(match s.running.get(&r.handle) {
            Some(programs) => classify::resolve_shell(programs),
            None => w.shell.unwrap_or(Shell::Unknown),
        }))
    }

    fn bring_to_foreground(&self, r: WindowRef) -> PlatformResult<FocusStep> {
        self.check_panic();
        let mut s = self.lock();
        let handle = r.handle;
        if !Self::owned(&s, r) {
            return Err(PlatformError::WindowGone);
        }
        if s.refuse_focus.contains(&handle) {
            s.calls.push(FakeCall::FocusRefused { handle });
            Self::say(&mut s, format!("focus REFUSED handle={handle}"));
            return Err(PlatformError::FocusRefused);
        }
        if let Some(w) = s.windows.iter_mut().find(|w| w.handle == handle) {
            w.is_minimized = false; // step 1: SW_RESTORE
        }
        let step = if s.foreground == Some(handle) {
            FocusStep::AlreadyForeground
        } else {
            s.focus_step.unwrap_or(FocusStep::SetForeground)
        };
        s.foreground = Some(handle);
        s.calls.push(FakeCall::Focus { handle, step });
        Self::say(&mut s, format!("focus handle={handle} step={}", step.as_str()));
        Ok(step)
    }

    fn restore(&self, r: WindowRef) -> PlatformResult<()> {
        self.check_panic();
        let mut s = self.lock();
        if !Self::owned(&s, r) {
            return Err(PlatformError::WindowGone);
        }
        let border = s.border_after_restore.remove(&r.handle);
        if let Some(w) = s.windows.iter_mut().find(|w| w.handle == r.handle) {
            w.is_minimized = false;
            w.is_maximized = false;
            if let Some(px) = border {
                let v = w.visible;
                w.outer = PixelRect::new(v.x - px, v.y, v.width + 2 * px, v.height + px);
            }
        }
        s.calls.push(FakeCall::Restore { handle: r.handle });
        Self::say(&mut s, format!("restore handle={}", r.handle));
        Ok(())
    }

    fn rects(&self, r: WindowRef) -> PlatformResult<WindowRects> {
        let s = self.lock();
        let Some(w) = s.windows.iter().find(|w| w.handle == r.handle && w.pid == r.pid) else {
            return Err(PlatformError::WindowGone);
        };
        Ok(WindowRects {
            outer: w.outer,
            visible: w.visible,
            is_minimized: w.is_minimized,
            is_maximized: w.is_maximized,
        })
    }

    fn move_windows(&self, moves: &[WindowMove]) -> Vec<PlatformResult<()>> {
        self.check_panic();
        let mut s = self.lock();
        let mut out = Vec::with_capacity(moves.len());
        for m in moves {
            let handle = m.window.handle;
            if !Self::owned(&s, m.window) {
                out.push(Err(PlatformError::WindowGone));
                continue;
            }
            if s.refuse_move.contains(&handle) {
                s.calls.push(FakeCall::MoveRefused { handle });
                Self::say(&mut s, format!("move REFUSED handle={handle}"));
                out.push(Err(PlatformError::Refused("elevated or refused".into())));
                continue;
            }
            s.calls.push(FakeCall::Move { handle, outer: m.outer });
            Self::say(
                &mut s,
                format!("move handle={handle} outer={},{} {}x{}", m.outer.x, m.outer.y, m.outer.width, m.outer.height),
            );
            let scale = s.rescale_once.remove(&handle);
            let min = s.min_size.get(&handle).copied();
            if let Some(w) = s.windows.iter_mut().find(|w| w.handle == handle) {
                // A minimized window does not take a move (SetWindowPos moves
                // its icon, not its restored rect): restore comes first.
                if !w.is_minimized {
                    let mut outer = m.outer;
                    if let Some(pct) = scale {
                        outer.width = outer.width * pct / 100;
                        outer.height = outer.height * pct / 100;
                    }
                    if let Some((mw, mh)) = min {
                        outer.width = outer.width.max(mw);
                        outer.height = outer.height.max(mh);
                    }
                    // Keep the window's own border: visible = outer minus it.
                    let (l, t) = (w.visible.x - w.outer.x, w.visible.y - w.outer.y);
                    let (r, b) = (w.outer.right() - w.visible.right(), w.outer.bottom() - w.visible.bottom());
                    w.outer = outer;
                    w.visible = PixelRect::new(outer.x + l, outer.y + t, outer.width - l - r, outer.height - t - b);
                    w.is_maximized = false;
                }
            }
            out.push(Ok(()));
        }
        out
    }

    fn minimize(&self, r: WindowRef) -> PlatformResult<()> {
        self.check_panic();
        let mut s = self.lock();
        if !Self::owned(&s, r) {
            return Err(PlatformError::WindowGone);
        }
        if let Some(w) = s.windows.iter_mut().find(|w| w.handle == r.handle) {
            // The restored rect is kept (traits: never -32000).
            w.is_minimized = true;
        }
        if s.foreground == Some(r.handle) {
            s.foreground = None;
        }
        s.calls.push(FakeCall::Minimize { handle: r.handle });
        Self::say(&mut s, format!("minimize handle={}", r.handle));
        Ok(())
    }

    fn close(&self, r: WindowRef) -> PlatformResult<()> {
        self.check_panic();
        let mut s = self.lock();
        if !Self::owned(&s, r) {
            return Err(PlatformError::WindowGone);
        }
        s.calls.push(FakeCall::Close { handle: r.handle });
        Self::say(&mut s, format!("close handle={}", r.handle));
        // A shell window accepts WM_CLOSE and goes away.
        s.windows.retain(|w| w.handle != r.handle);
        if s.foreground == Some(r.handle) {
            s.foreground = None;
        }
        Ok(())
    }

    fn input_access(&self, r: WindowRef) -> PlatformResult<InputAccess> {
        self.check_panic();
        let mut s = self.lock();
        if !Self::owned(&s, r) {
            return Err(PlatformError::WindowGone);
        }
        s.calls.push(FakeCall::InputAccess { handle: r.handle });
        if let Some(e) = s.input_access_error.get(&r.handle).cloned() {
            Self::say(&mut s, format!("access handle={} FAILED", r.handle));
            return Err(e);
        }
        let access = s.input_access.get(&r.handle).copied().unwrap_or(InputAccess::Allowed);
        if access != InputAccess::Allowed {
            Self::say(&mut s, format!("access handle={} {}", r.handle, access.as_str()));
        }
        Ok(access)
    }
}

impl InputBackend for FakePlatform {
    fn send_units(&self, r: WindowRef, units: &[u16]) -> PlatformResult<usize> {
        self.check_panic();
        // Block WITHOUT holding the lock, so listing keeps working: this is
        // what the hang guard test leans on.
        let block = self.lock().block_typing;
        if let Some(d) = block {
            std::thread::sleep(d);
        }
        let mut s = self.lock();
        let target = Self::input_target(&s, r)?;
        let n = s.input_limit.map_or(units.len(), |l| l.min(units.len()));
        let landed = String::from_utf16_lossy(&units[..n]);
        let to = target.unwrap_or(0);
        let mut line = format!("type handle={} units={}", r.handle, units.len());
        if n < units.len() {
            line.push_str(&format!(" BLOCKED inserted={n}"));
        }
        if target != Some(r.handle) {
            line.push_str(&format!(" landed_in={to}"));
        }
        Self::say(&mut s, line);
        if n > 0 {
            s.calls.push(FakeCall::TypeText { handle: to, text: landed.clone() });
            // One entry per batch (a text over 32 units shows as several).
            s.typed.entry(to).or_default().push(Typed::Text(landed));
            Self::after_input(&mut s);
        }
        Ok(n)
    }

    fn press_key(&self, r: WindowRef, chord: KeyChord) -> PlatformResult<usize> {
        self.check_panic();
        let mut s = self.lock();
        let target = Self::input_target(&s, r)?;
        let n = s.input_limit.map_or(chord.input_count(), |l| l.min(chord.input_count()));
        let to = target.unwrap_or(0);
        let mut line = format!("key handle={} chord={}", r.handle, chord.describe());
        if n < chord.input_count() {
            line.push_str(&format!(" BLOCKED inserted={n}"));
            Self::say(&mut s, line);
            return Ok(n);
        }
        if target != Some(r.handle) {
            line.push_str(&format!(" landed_in={to}"));
        }
        Self::say(&mut s, line);
        s.calls.push(FakeCall::Key { handle: to, chord });
        s.typed.entry(to).or_default().push(Typed::Key(chord));
        Self::after_input(&mut s);
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::classify::TerminalHost;
    use crate::services::multiline_policy::Shell;

    fn fixture() -> Fixture {
        Fixture::parse(
            r#"{
              "displays":[{"deviceName":"\\\\.\\DISPLAY1","name":"FakeWindows Display",
                 "bounds":{"x":0,"y":0,"width":1920,"height":1080},
                 "workArea":{"x":0,"y":0,"width":1920,"height":1040},"isPrimary":true}],
              "foreground": 1,
              "windows":[
                {"handle":1,"pid":10,"title":"PowerShell","className":"CASCADIA_HOSTING_WINDOW_CLASS",
                 "exePath":"C:\\WT\\WindowsTerminal.exe","shells":["pwsh.exe"],
                 "visible":{"x":0,"y":0,"width":800,"height":600}},
                {"handle":2,"pid":20,"title":"cmd","className":"ConsoleWindowClass",
                 "shells":["cmd.exe"],"visible":{"x":900,"y":0,"width":800,"height":600}}
              ]}"#,
        )
        .unwrap()
    }

    #[test]
    fn fixture_windows_are_classified() {
        let p = FakePlatform::from_fixture(&fixture());
        let w = p.list_windows().unwrap();
        assert_eq!(w[0].terminal, Some(TerminalHost::WindowsTerminal));
        assert_eq!(w[0].shell, Some(Shell::Pwsh));
        assert_eq!(w[1].app, "Command Prompt");
        assert_eq!(w[0].outer, PixelRect::new(-7, 0, 814, 607));
    }

    #[test]
    fn fixture_validation() {
        assert!(Fixture::parse("{").is_err());
        assert!(Fixture::parse(r#"{"displays":[],"windows":[]}"#).is_err(), "needs a primary");
    }

    const W1: WindowRef = WindowRef { handle: 1, pid: 10 };
    const W2: WindowRef = WindowRef { handle: 2, pid: 20 };

    #[test]
    fn focus_reports_the_step_and_refusal() {
        let p = FakePlatform::from_fixture(&fixture());
        assert_eq!(p.bring_to_foreground(W1), Ok(FocusStep::AlreadyForeground));
        p.set_focus_step(FocusStep::AltFallback);
        assert_eq!(p.bring_to_foreground(W2), Ok(FocusStep::AltFallback));
        p.set_refuse_focus(1, true);
        assert_eq!(p.bring_to_foreground(W1), Err(PlatformError::FocusRefused));
        assert_eq!(p.foreground(), Some(2));
        assert_eq!(p.bring_to_foreground(WindowRef { handle: 99, pid: 1 }), Err(PlatformError::WindowGone));
        assert_eq!(p.foreground_window(), Ok(Some(W2)));
    }

    #[test]
    fn every_call_checks_the_pid_still_owns_the_handle() {
        let p = FakePlatform::from_fixture(&fixture());
        p.reuse_handle(1, 77, "someone else");
        let stale = W1;
        assert_eq!(p.bring_to_foreground(stale), Err(PlatformError::WindowGone));
        assert_eq!(p.send_units(stale, &[0x61]), Err(PlatformError::WindowGone));
        assert_eq!(p.press_key(stale, KeyChord::RETURN), Err(PlatformError::WindowGone));
        assert_eq!(p.minimize(stale), Err(PlatformError::WindowGone));
        assert_eq!(p.close(stale), Err(PlatformError::WindowGone));
        assert_eq!(p.current_shell(stale), Err(PlatformError::WindowGone));
        assert_eq!(p.restore(stale), Err(PlatformError::WindowGone));
        assert_eq!(p.rects(stale), Err(PlatformError::WindowGone));
        let mv = WindowMove { window: stale, outer: PixelRect::new(0, 0, 1, 1) };
        assert_eq!(p.move_windows(&[mv]), vec![Err(PlatformError::WindowGone)]);
        assert!(p.typed(1).is_empty() && p.calls().is_empty());
        assert_eq!(p.foreground_window(), Ok(Some(WindowRef { handle: 1, pid: 77 })));
    }

    #[test]
    fn input_lands_in_the_foreground_window_when_the_guard_is_off() {
        let p = FakePlatform::from_fixture(&fixture());
        assert_eq!(p.send_units(W2, &[0x61]), Err(PlatformError::FocusLost { after_chars: 0 }), "guard on");
        p.set_input_guard(false);
        assert_eq!(p.send_units(W2, &[0x61, 0x62]), Ok(2));
        assert_eq!(p.press_key(W2, KeyChord::RETURN), Ok(2));
        assert_eq!(p.typed(1), vec![Typed::Text("ab".into()), Typed::Key(KeyChord::RETURN)], "like SendInput");
        assert!(p.typed(2).is_empty());
    }

    #[test]
    fn steal_and_limit() {
        let p = FakePlatform::from_fixture(&fixture());
        p.set_steal_focus(2, 2);
        p.send_units(W1, &[0x61]).unwrap();
        assert_eq!(p.foreground(), Some(1));
        p.press_key(W1, KeyChord::RETURN).unwrap();
        assert_eq!(p.foreground(), Some(2), "stolen after the second input");
        p.set_input_limit(Some(1));
        assert_eq!(p.send_units(W2, &[0x61, 0x62, 0x63]), Ok(1));
        assert_eq!(p.press_key(W2, KeyChord::SHIFT_ENTER), Ok(1));
        assert_eq!(p.typed(2), vec![Typed::Text("a".into())], "a blocked chord lands nothing");
        p.set_input_limit(Some(0));
        assert_eq!(p.send_units(W2, &[0x61]), Ok(0));
    }

    #[test]
    fn current_shell_sees_a_program_started_after_the_listing() {
        let p = FakePlatform::from_fixture(&fixture());
        assert_eq!(p.current_shell(W1), Ok(Some(Shell::Pwsh)));
        p.set_running(1, &["pwsh.exe", "python.exe"]);
        assert_eq!(p.current_shell(W1), Ok(Some(Shell::Unknown)));
        assert_eq!(p.list_windows().unwrap()[0].shell, Some(Shell::Pwsh), "the listing is stale");
        let notes = window_from_fixture(&FixtureWindow {
            handle: 3,
            pid: 30,
            title: "n".into(),
            class_name: "Notepad".into(),
            exe_path: None,
            product_name: None,
            shells: vec![],
            visible: FixtureRect { x: 0, y: 0, width: 1, height: 1 },
            border: 0,
            is_minimized: false,
        });
        p.add_window(notes);
        assert_eq!(p.current_shell(WindowRef { handle: 3, pid: 30 }), Ok(None));
    }

    #[test]
    fn every_action_is_one_line_with_counts_never_text() {
        let p = FakePlatform::from_fixture(&fixture());
        p.bring_to_foreground(W1).unwrap();
        p.send_units(W1, &"secret".encode_utf16().collect::<Vec<_>>()).unwrap();
        p.press_key(W1, KeyChord::SHIFT_ENTER).unwrap();
        p.restore(W2).unwrap();
        p.move_windows(&[WindowMove { window: W2, outer: PixelRect::new(0, 0, 10, 10) }]);
        p.minimize(W2).unwrap();
        p.close(W2).unwrap();
        p.set_refuse_focus(1, true);
        let _ = p.bring_to_foreground(W1);
        assert_eq!(
            p.actions(),
            vec![
                "focus handle=1 step=already",
                "type handle=1 units=6",
                "key handle=1 chord=shift+return",
                "restore handle=2",
                "move handle=2 outer=0,0 10x10",
                "minimize handle=2",
                "close handle=2",
                "focus REFUSED handle=1",
            ]
        );
        assert!(!p.actions().join(" ").contains("secret"));
    }

    #[test]
    fn blocked_and_misdirected_input_say_so() {
        let p = FakePlatform::from_fixture(&fixture());
        p.set_input_guard(false);
        p.set_input_limit(Some(1));
        p.send_units(W2, &[0x61, 0x62]).unwrap();
        p.press_key(W1, KeyChord::RETURN).unwrap();
        assert_eq!(
            p.actions(),
            vec![
                "type handle=2 units=2 BLOCKED inserted=1 landed_in=1",
                "key handle=1 chord=return BLOCKED inserted=1"
            ]
        );
    }

    #[test]
    #[should_panic(expected = "fake input lane panic")]
    fn panic_input_panics() {
        let p = FakePlatform::from_fixture(&fixture());
        p.set_panic_input(true);
        let _ = p.minimize(W1);
    }

    #[test]
    fn moves_keep_the_border_and_refusals_do_not_stop_others() {
        let p = FakePlatform::from_fixture(&fixture());
        p.set_refuse_move(2, true);
        let r = p.move_windows(&[
            WindowMove { window: W2, outer: PixelRect::new(0, 0, 10, 10) },
            WindowMove { window: W1, outer: PixelRect::new(-7, 0, 974, 1047) },
        ]);
        assert!(r[0].is_err() && r[1].is_ok());
        assert_eq!(p.windows()[0].visible, PixelRect::new(0, 0, 960, 1040));
    }

    #[test]
    fn close_and_minimize() {
        let p = FakePlatform::from_fixture(&fixture());
        let before = p.windows()[1].visible;
        p.minimize(W2).unwrap();
        assert!(p.windows()[1].is_minimized);
        assert_eq!(p.windows()[1].visible, before, "a minimized window keeps its restored rect");
        p.close(W1).unwrap();
        assert_eq!(p.windows().len(), 1);
        assert_eq!(p.foreground(), None);
        assert_eq!(p.close(W1), Err(PlatformError::WindowGone));
    }
}
