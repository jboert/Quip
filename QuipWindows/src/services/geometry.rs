//! Display geometry (`Shared/DisplayGeometry.swift`): every window is
//! normalized against ITS OWN display, and each display carries its slot in
//! the desktop span, so the phone can draw one display or all of them.
//!
//! Which display a window is on: the one containing its CENTER, falling back
//! to the primary (`DisplayGeometry.displayID(forWindow:displays:)`). The spec
//! (3.4) says "the display holding most of its area"; the Swift rule wins so
//! both peers agree about straddling windows.

use crate::protocol::types::WindowFrame;

/// `DisplayRect`. Half-open containment, like Swift.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DisplayRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl DisplayRect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x && px < self.max_x() && py >= self.y && py < self.max_y()
    }
}

/// `DisplayGeometry.normalize`: zero frame for a degenerate display.
pub fn normalize(window: DisplayRect, display: DisplayRect) -> WindowFrame {
    if display.width <= 0.0 || display.height <= 0.0 {
        return WindowFrame::ZERO;
    }
    WindowFrame {
        x: (window.x - display.x) / display.width,
        y: (window.y - display.y) / display.height,
        width: window.width / display.width,
        height: window.height / display.height,
    }
}

/// `DisplayGeometry.span`: bounding box; unit rect when empty.
pub fn span(displays: &[DisplayRect]) -> DisplayRect {
    let Some(first) = displays.first() else { return DisplayRect::new(0.0, 0.0, 1.0, 1.0) };
    let (mut min_x, mut min_y, mut max_x, mut max_y) = (first.x, first.y, first.max_x(), first.max_y());
    for d in &displays[1..] {
        min_x = min_x.min(d.x);
        min_y = min_y.min(d.y);
        max_x = max_x.max(d.max_x());
        max_y = max_y.max(d.max_y());
    }
    DisplayRect::new(min_x, min_y, max_x - min_x, max_y - min_y)
}

/// `DisplayGeometry.spanFrame(of:in:)`.
pub fn span_frame(display: DisplayRect, span: DisplayRect) -> WindowFrame {
    normalize(display, span)
}

/// `DisplayGeometry.spanFrame(ofWindow:onDisplay:)` (the phone's compose).
pub fn compose(window: WindowFrame, display: WindowFrame) -> WindowFrame {
    WindowFrame {
        x: display.x + window.x * display.width,
        y: display.y + window.y * display.height,
        width: window.width * display.width,
        height: window.height * display.height,
    }
}

/// One display as the assignment rule sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct DisplayEntry {
    pub id: String,
    pub is_primary: bool,
    pub rect: DisplayRect,
}

/// `DisplayGeometry.displayID(forWindow:displays:)`.
pub fn display_id_for_window(window: DisplayRect, displays: &[DisplayEntry]) -> Option<String> {
    let first = displays.first()?;
    if let Some(hit) = displays.iter().find(|d| d.rect.contains(window.mid_x(), window.mid_y())) {
        return Some(hit.id.clone());
    }
    Some(displays.iter().find(|d| d.is_primary).unwrap_or(first).id.clone())
}

/// Whether the center lies on some display (`isOnVisibleScreen` on the Mac:
/// a window in a gap gets the primary's id but is NOT on screen).
pub fn is_on_visible_display(window: DisplayRect, displays: &[DisplayEntry]) -> bool {
    displays.iter().any(|d| d.rect.contains(window.mid_x(), window.mid_y()))
}

/// width / height, or `None` when degenerate.
pub fn aspect(r: DisplayRect) -> Option<f64> {
    (r.height > 0.0).then(|| r.width / r.height)
}

/// A display's id on the wire (spec 3.4): stable per monitor device name
/// (`\\.\DISPLAY1`), hashed so it is opaque, as `CGDirectDisplayID` is on the
/// Mac. FNV-1a 64: stable across runs and builds, unlike `DefaultHasher`.
pub fn display_wire_id(device_name: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in device_name.as_bytes() {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("d-{h:016x}")
}

#[cfg(test)]
mod tests {
    //! `Shared/Tests/DisplayGeometryTests.swift` (geometry half; the wire
    //! cases are in `protocol::messages`).
    #![allow(non_snake_case)]
    use super::*;

    const EPS: f64 = 1e-4;

    fn primary() -> DisplayRect {
        DisplayRect::new(0.0, 0.0, 3440.0, 1440.0)
    }
    fn secondary() -> DisplayRect {
        DisplayRect::new(3440.0, 0.0, 2560.0, 1440.0)
    }
    fn displays() -> Vec<DisplayEntry> {
        vec![
            DisplayEntry { id: "d-primary".into(), is_primary: true, rect: primary() },
            DisplayEntry { id: "d-second".into(), is_primary: false, rect: secondary() },
        ]
    }
    fn on_canvas(f: WindowFrame) {
        assert!(f.x >= 0.0 && f.y >= 0.0 && f.x + f.width <= 1.0001 && f.y + f.height <= 1.0001, "{f:?}");
    }

    #[test]
    fn testSecondScreenWindowLandsOnCanvasWhenNormalizedAgainstItsOwnDisplay() {
        let terminal = DisplayRect::new(3600.0, 200.0, 1200.0, 800.0);
        let wrong = normalize(terminal, primary());
        assert!(wrong.x > 1.0);
        let right = normalize(terminal, secondary());
        on_canvas(right);
        assert!((right.x - 160.0 / 2560.0).abs() < EPS);
        assert!((right.width - 1200.0 / 2560.0).abs() < EPS);
    }

    #[test]
    fn testPrimaryWindowIsUnaffectedByTheSecondScreen() {
        let f = normalize(DisplayRect::new(200.0, 100.0, 1200.0, 800.0), primary());
        assert!((f.x - 200.0 / 3440.0).abs() < EPS);
        assert!((f.y - 100.0 / 1440.0).abs() < EPS);
    }

    #[test]
    fn testDegenerateDisplayYieldsZeroFrameNotNaN() {
        let f = normalize(DisplayRect::new(1.0, 1.0, 10.0, 10.0), DisplayRect::new(0.0, 0.0, 0.0, 1080.0));
        assert_eq!(f, WindowFrame::ZERO);
        let f = normalize(DisplayRect::new(1.0, 1.0, 10.0, 10.0), DisplayRect::new(0.0, 0.0, 1920.0, 0.0));
        assert_eq!(f, WindowFrame::ZERO);
    }

    #[test]
    fn testSpanCoversBothDisplays() {
        let s = span(&[primary(), secondary()]);
        assert_eq!((s.x, s.width, s.height), (0.0, 6000.0, 1440.0));
    }

    #[test]
    fn testSpanHandlesADisplayLeftOfPrimary() {
        let left = DisplayRect::new(-2560.0, 0.0, 2560.0, 1440.0);
        let s = span(&[primary(), left]);
        assert_eq!((s.x, s.width), (-2560.0, 6000.0));
        let f = span_frame(left, s);
        assert!(f.x.abs() < EPS);
        assert!((f.width - 2560.0 / 6000.0).abs() < EPS);
    }

    #[test]
    fn span_handles_a_display_above() {
        let above = DisplayRect::new(0.0, -1080.0, 1920.0, 1080.0);
        let s = span(&[primary(), above]);
        assert_eq!((s.y, s.height), (-1080.0, 2520.0));
    }

    #[test]
    fn testSingleDisplaySpanIsTheUnitRect() {
        let s = span(&[primary()]);
        assert_eq!(span_frame(primary(), s), WindowFrame::UNIT);
    }

    #[test]
    fn testEmptyDisplayListDoesNotDivideByZero() {
        let s = span(&[]);
        assert_eq!((s.width, s.height), (1.0, 1.0));
    }

    #[test]
    fn testComposingBackOntoTheSpanReproducesTheTrueGlobalPosition() {
        let terminal = DisplayRect::new(3600.0, 200.0, 1200.0, 800.0);
        let s = span(&[primary(), secondary()]);
        let composed = compose(normalize(terminal, secondary()), span_frame(secondary(), s));
        let direct = normalize(terminal, s);
        assert!((composed.x - direct.x).abs() < EPS);
        assert!((composed.y - direct.y).abs() < EPS);
        assert!((composed.width - direct.width).abs() < EPS);
        assert!((composed.height - direct.height).abs() < EPS);
        on_canvas(composed);
    }

    #[test]
    fn testComposingOnASingleDisplayIsIdentity() {
        let f = WindowFrame { x: 0.25, y: 0.5, width: 0.3, height: 0.2 };
        assert_eq!(compose(f, WindowFrame::UNIT), f);
    }

    #[test]
    fn testWindowIsAssignedToTheDisplayContainingItsCenter() {
        let d = displays();
        assert_eq!(
            display_id_for_window(DisplayRect::new(3600.0, 200.0, 1200.0, 800.0), &d).as_deref(),
            Some("d-second")
        );
        assert_eq!(
            display_id_for_window(DisplayRect::new(200.0, 100.0, 1200.0, 800.0), &d).as_deref(),
            Some("d-primary")
        );
    }

    #[test]
    fn testWindowStraddlingTheSeamGoesWhereItsCenterIs() {
        let d = displays();
        assert_eq!(
            display_id_for_window(DisplayRect::new(3200.0, 100.0, 1200.0, 800.0), &d).as_deref(),
            Some("d-second")
        );
    }

    #[test]
    fn center_exactly_on_the_seam_belongs_to_the_right_display() {
        // Half-open: x = 3440 is the second display's first column.
        let d = displays();
        assert_eq!(display_id_for_window(DisplayRect::new(3340.0, 0.0, 200.0, 100.0), &d).as_deref(), Some("d-second"));
    }

    #[test]
    fn testWindowInAGapFallsBackToPrimaryRatherThanVanishing() {
        let list = vec![
            DisplayEntry {
                id: "d-short".into(),
                is_primary: false,
                rect: DisplayRect::new(3440.0, 0.0, 2560.0, 720.0),
            },
            DisplayEntry { id: "d-primary".into(), is_primary: true, rect: DisplayRect::new(0.0, 0.0, 3440.0, 1440.0) },
        ];
        let orphan = DisplayRect::new(4000.0, 1000.0, 400.0, 300.0);
        assert_eq!(display_id_for_window(orphan, &list).as_deref(), Some("d-primary"));
        assert!(!is_on_visible_display(orphan, &list));
    }

    #[test]
    fn gap_without_a_primary_falls_back_to_the_first() {
        let list = vec![DisplayEntry { id: "only".into(), is_primary: false, rect: primary() }];
        assert_eq!(display_id_for_window(DisplayRect::new(9000.0, 9000.0, 10.0, 10.0), &list).as_deref(), Some("only"));
    }

    #[test]
    fn testNoDisplaysMeansNoDisplayID() {
        assert_eq!(display_id_for_window(DisplayRect::new(0.0, 0.0, 100.0, 100.0), &[]), None);
    }

    #[test]
    fn wire_id_is_stable_opaque_and_distinct() {
        let a = display_wire_id(r"\\.\DISPLAY1");
        assert_eq!(a, display_wire_id(r"\\.\DISPLAY1"));
        assert_ne!(a, display_wire_id(r"\\.\DISPLAY2"));
        assert!(!a.contains("DISPLAY"));
        // Pinned so a change to the hash is a deliberate, visible break of
        // every phone's saved display chip.
        assert_eq!(display_wire_id(""), "d-cbf29ce484222325");
    }

    #[test]
    fn aspect_of_degenerate_is_none() {
        assert_eq!(aspect(DisplayRect::new(0.0, 0.0, 16.0, 9.0)), Some(16.0 / 9.0));
        assert_eq!(aspect(DisplayRect::new(0.0, 0.0, 16.0, 0.0)), None);
    }

    #[test]
    fn rect_helpers_and_offset_normalize_and_compose() {
        let r = DisplayRect::new(10.0, 20.0, 100.0, 50.0);
        assert_eq!((r.mid_x(), r.mid_y()), (60.0, 45.0));
        assert!(r.contains(10.0, 20.0) && !r.contains(110.0, 30.0) && !r.contains(50.0, 70.0));
        let f = normalize(DisplayRect::new(60.0, 45.0, 50.0, 25.0), r);
        assert_eq!(f, WindowFrame { x: 0.5, y: 0.5, width: 0.5, height: 0.5 });
        let c = compose(
            WindowFrame { x: 0.5, y: 0.5, width: 0.5, height: 0.5 },
            WindowFrame { x: 0.5, y: 0.0, width: 0.5, height: 0.5 },
        );
        assert_eq!(c, WindowFrame { x: 0.75, y: 0.25, width: 0.25, height: 0.25 });
        assert_eq!(display_wire_id(r"\\.\DISPLAY1"), display_wire_id(r"\\.\DISPLAY1"));
        assert_eq!(display_wire_id("a"), "d-af63dc4c8601ec8c");
    }
}
