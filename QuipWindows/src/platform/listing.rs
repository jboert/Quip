//! The rules the Win32 lister applies to what Windows reports (spec 5.1),
//! kept pure so they run on the Mac. `win32` gathers the facts; this decides.

use crate::platform::traits::PlatformDisplay;
use crate::services::layout::PixelRect;

/// `WS_EX_TOOLWINDOW`: palettes and floating toolbars, not app windows.
pub const WS_EX_TOOLWINDOW: u32 = 0x0000_0080;

/// The desktop and the taskbar: visible, titled on some builds, never a
/// window the user means.
pub const SHELL_CLASSES: [&str; 4] = ["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"];

/// What the lister read about one `EnumWindows` handle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListingFacts<'a> {
    pub pid: u32,
    /// The process whose own windows are left out (Quip itself), if any.
    pub own_pid: Option<u32>,
    pub visible: bool,
    pub title: &'a str,
    /// `GetWindow(GW_OWNER)` is not null: a dialog or popup of another window.
    pub has_owner: bool,
    /// `GWL_EXSTYLE`.
    pub ex_style: u32,
    /// `DWMWA_CLOAKED` is non-zero: a hidden UWP frame or a window on another
    /// virtual desktop.
    pub cloaked: bool,
    pub class_name: &'a str,
}

/// Spec 5.1: visible, titled, unowned, not a tool window, not cloaked, not
/// Quip's own, not the shell.
pub fn keeps_window(f: &ListingFacts) -> bool {
    rejected_by(f).is_none()
}

/// The first rule of `keeps_window` that drops the window, by name, or
/// `None` when it is kept. Failure messages print it.
pub fn rejected_by(f: &ListingFacts) -> Option<&'static str> {
    if !f.visible {
        Some("hidden")
    } else if f.title.is_empty() {
        Some("untitled")
    } else if f.has_owner {
        Some("owned")
    } else if f.ex_style & WS_EX_TOOLWINDOW != 0 {
        Some("tool")
    } else if f.cloaked {
        Some("cloaked")
    } else if f.own_pid == Some(f.pid) {
        Some("own")
    } else if SHELL_CLASSES.contains(&f.class_name) {
        Some("shell")
    } else {
        None
    }
}

/// A Win32 `RECT` (left, top, right, bottom) as a `PixelRect`.
pub fn rect_from_ltrb(left: i32, top: i32, right: i32, bottom: i32) -> PixelRect {
    PixelRect::new(left, top, right - left, bottom - top)
}

/// `WINDOWPLACEMENT.rcNormalPosition` is in workspace coordinates: relative
/// to the work area of the window's monitor, not to the screen. With the
/// taskbar on the left or at the top the two differ, so shift it by the work
/// area's offset into its monitor to get the screen rect the window comes
/// back to.
pub fn restored_rect(normal: PixelRect, monitor: PixelRect, work_area: PixelRect) -> PixelRect {
    PixelRect::new(
        normal.x + (work_area.x - monitor.x),
        normal.y + (work_area.y - monitor.y),
        normal.width,
        normal.height,
    )
}

/// Exactly one display is primary (the host and the phone both rely on it).
/// Windows always flags one; if it ever flags none, the display at the
/// origin (where Windows puts the primary), else the first, becomes primary;
/// if several, the first flagged one stays.
pub fn ensure_one_primary(displays: &mut [PlatformDisplay]) {
    let chosen = displays
        .iter()
        .position(|d| d.is_primary)
        .or_else(|| displays.iter().position(|d| d.bounds.x == 0 && d.bounds.y == 0))
        .unwrap_or(0);
    for (i, d) in displays.iter_mut().enumerate() {
        d.is_primary = i == chosen;
    }
}

/// The phone's chip name for a monitor: the adapter's description of it
/// (`EnumDisplayDevicesW`), else the device name without the `\\.\` prefix.
pub fn display_name(device_name: &str, description: Option<&str>) -> String {
    description
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| device_name.trim_start_matches(r"\\.\").to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts<'a>() -> ListingFacts<'a> {
        ListingFacts {
            pid: 40,
            own_pid: Some(7),
            visible: true,
            title: "Notes - Notepad",
            has_owner: false,
            ex_style: 0x0000_0100, // WS_EX_WINDOWEDGE
            cloaked: false,
            class_name: "Notepad",
        }
    }

    #[test]
    fn an_ordinary_app_window_is_kept() {
        assert!(keeps_window(&facts()));
        assert!(keeps_window(&ListingFacts { own_pid: None, ..facts() }));
    }

    #[test]
    fn each_filter_drops_the_window() {
        let cases: [(&str, ListingFacts); 7] = [
            ("hidden", ListingFacts { visible: false, ..facts() }),
            ("untitled", ListingFacts { title: "", ..facts() }),
            ("owned", ListingFacts { has_owner: true, ..facts() }),
            ("tool", ListingFacts { ex_style: WS_EX_TOOLWINDOW | 0x100, ..facts() }),
            ("cloaked", ListingFacts { cloaked: true, ..facts() }),
            ("own", ListingFacts { pid: 7, ..facts() }),
            ("shell", ListingFacts { class_name: "Shell_TrayWnd", ..facts() }),
        ];
        for (name, f) in cases {
            assert!(!keeps_window(&f), "{name}");
            assert_eq!(rejected_by(&f), Some(name));
        }
        assert_eq!(rejected_by(&facts()), None);
        let hidden_untitled = ListingFacts { visible: false, title: "", ..facts() };
        assert_eq!(rejected_by(&hidden_untitled), Some("hidden"), "the first rule that fails is named");
        for class in SHELL_CLASSES {
            assert!(!keeps_window(&ListingFacts { class_name: class, ..facts() }), "{class}");
        }
    }

    #[test]
    fn rect_from_win32_edges() {
        assert_eq!(rect_from_ltrb(-7, 0, 953, 1047), PixelRect::new(-7, 0, 960, 1047));
        assert_eq!(rect_from_ltrb(1920, -200, 3840, 880), PixelRect::new(1920, -200, 1920, 1080));
    }

    #[test]
    fn restored_rect_adds_the_work_area_offset() {
        let normal = PixelRect::new(100, 120, 640, 480);
        let monitor = PixelRect::new(0, 0, 1920, 1080);
        assert_eq!(restored_rect(normal, monitor, PixelRect::new(0, 0, 1920, 1040)), normal, "taskbar at the bottom");
        assert_eq!(
            restored_rect(normal, monitor, PixelRect::new(0, 48, 1920, 1032)),
            PixelRect::new(100, 168, 640, 480),
            "taskbar at the top"
        );
        let right = PixelRect::new(1920, 0, 2560, 1440);
        assert_eq!(
            restored_rect(PixelRect::new(10, 10, 800, 600), right, PixelRect::new(1982, 0, 2498, 1440)),
            PixelRect::new(72, 10, 800, 600),
            "taskbar on the left of a second monitor: only the offset moves it"
        );
    }

    fn display(device: &str, x: i32, primary: bool) -> PlatformDisplay {
        PlatformDisplay {
            device_name: device.into(),
            name: device.into(),
            bounds: PixelRect::new(x, 0, 1920, 1080),
            work_area: PixelRect::new(x, 0, 1920, 1040),
            is_primary: primary,
        }
    }

    fn primaries(d: &[PlatformDisplay]) -> Vec<&str> {
        d.iter().filter(|d| d.is_primary).map(|d| d.device_name.as_str()).collect()
    }

    #[test]
    fn exactly_one_primary() {
        let mut d = vec![display("A", -1920, false), display("B", 0, true)];
        ensure_one_primary(&mut d);
        assert_eq!(primaries(&d), ["B"]);
        let mut d = vec![display("A", -1920, false), display("B", 0, false)];
        ensure_one_primary(&mut d);
        assert_eq!(primaries(&d), ["B"], "none flagged: the one at the origin");
        let mut d = vec![display("A", 1920, false), display("B", 3840, false)];
        ensure_one_primary(&mut d);
        assert_eq!(primaries(&d), ["A"], "none at the origin: the first");
        let mut d = vec![display("A", 0, true), display("B", 1920, true)];
        ensure_one_primary(&mut d);
        assert_eq!(primaries(&d), ["A"]);
        let mut empty: Vec<PlatformDisplay> = vec![];
        ensure_one_primary(&mut empty);
    }

    #[test]
    fn display_names() {
        assert_eq!(display_name(r"\\.\DISPLAY2", Some(" Dell U2720Q ")), "Dell U2720Q");
        assert_eq!(display_name(r"\\.\DISPLAY2", Some("")), "DISPLAY2");
        assert_eq!(display_name(r"\\.\DISPLAY1", None), "DISPLAY1");
    }
}
