//! Arrange math (spec 5.2), pure.
//!
//! - `calculate`: `LayoutCalculator` (`QuipMac/Models/LayoutPreset.swift`):
//!   N equal columns or rows in 0..1 space (grid kept for parity; the phone
//!   never sends it, `arrange_windows` is horizontal | vertical only).
//! - `to_pixels`: place the normalized rects on the primary display's WORK
//!   AREA (`MONITORINFO.rcWork`, which excludes the taskbar on whichever edge it
//!   sits). Edges are rounded once and shared by neighbours, so tiles touch
//!   with no 1 px gaps; each rect is within 1 px of the Mac's fractional
//!   `toCGRect`.
//! - `compensate_border`: Windows 10/11 windows have an invisible resize
//!   border; `SetWindowPos` takes the OUTER rect while the user sees the DWM
//!   extended-frame rect. Grow the visible target by the per-edge difference.
//! - `ArrangeOutcome`: `QuipMac/Services/ArrangeOutcome.swift`, extended with
//!   the Windows-only "some windows refused" (elevated / UIPI) case.

use crate::protocol::types::ArrangeLayout;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayoutMode {
    Columns,
    Rows,
    Grid,
}

impl LayoutMode {
    /// `LayoutMode.from(arrangeLayout:)`: horizontal = side by side = columns.
    pub fn from_arrange(layout: ArrangeLayout) -> LayoutMode {
        match layout {
            ArrangeLayout::Horizontal => LayoutMode::Columns,
            ArrangeLayout::Vertical => LayoutMode::Rows,
        }
    }

    /// The deprecated string overload: exact, case-sensitive.
    pub fn from_arrange_str(s: &str) -> Option<LayoutMode> {
        match s {
            "horizontal" => Some(LayoutMode::Columns),
            "vertical" => Some(LayoutMode::Rows),
            _ => None,
        }
    }
}

/// `NormalizedRect` (0..1).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NormRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Physical-pixel rect (the process is per-monitor DPI aware v2, spec 5.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct PixelRect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl PixelRect {
    pub fn new(x: i32, y: i32, width: i32, height: i32) -> Self {
        Self { x, y, width, height }
    }
    pub fn right(&self) -> i32 {
        self.x + self.width
    }
    pub fn bottom(&self) -> i32 {
        self.y + self.height
    }
}

/// `LayoutCalculator.calculate`.
pub fn calculate(mode: LayoutMode, count: usize) -> Vec<NormRect> {
    if count == 0 {
        return vec![];
    }
    let n = count as f64;
    match mode {
        LayoutMode::Columns => {
            (0..count).map(|i| NormRect { x: i as f64 / n, y: 0.0, width: 1.0 / n, height: 1.0 }).collect()
        }
        LayoutMode::Rows => {
            (0..count).map(|i| NormRect { x: 0.0, y: i as f64 / n, width: 1.0, height: 1.0 / n }).collect()
        }
        LayoutMode::Grid => {
            let cols = n.sqrt().ceil() as usize;
            let rows = count.div_ceil(cols);
            let (cw, ch) = (1.0 / cols as f64, 1.0 / rows as f64);
            (0..count)
                .map(|i| NormRect { x: (i % cols) as f64 * cw, y: (i / cols) as f64 * ch, width: cw, height: ch })
                .collect()
        }
    }
}

fn edge(origin: i32, extent: i32, frac: f64) -> i32 {
    origin + (frac * f64::from(extent)).round() as i32
}

/// Normalized rects onto `area` with shared, rounded edges.
pub fn to_pixels(rects: &[NormRect], area: PixelRect) -> Vec<PixelRect> {
    rects
        .iter()
        .map(|r| {
            let l = edge(area.x, area.width, r.x);
            let t = edge(area.y, area.height, r.y);
            let rt = edge(area.x, area.width, r.x + r.width);
            let b = edge(area.y, area.height, r.y + r.height);
            PixelRect::new(l, t, rt - l, b - t)
        })
        .collect()
}

/// The visible target rects for `count` windows on `work_area`.
pub fn arrange(layout: ArrangeLayout, count: usize, work_area: PixelRect) -> Vec<PixelRect> {
    to_pixels(&calculate(LayoutMode::from_arrange(layout), count), work_area)
}

/// Grow the visible `target` by the invisible border, measured as the
/// per-edge difference between the window's `GetWindowRect` (`outer`) and its
/// `DWMWA_EXTENDED_FRAME_BOUNDS` (`visible`).
pub fn compensate_border(target: PixelRect, outer: PixelRect, visible: PixelRect) -> PixelRect {
    let left = visible.x - outer.x;
    let top = visible.y - outer.y;
    let right = outer.right() - visible.right();
    let bottom = outer.bottom() - visible.bottom();
    PixelRect::new(target.x - left, target.y - top, target.width + left + right, target.height + top + bottom)
}

/// What an arrange did (`ArrangeOutcome`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArrangeOutcome {
    Arranged,
    NoWindows,
    NoDisplay,
    /// Windows that did not move (elevated, UIPI). The others did.
    Refused {
        refused: usize,
        total: usize,
    },
}

impl ArrangeOutcome {
    /// `ArrangeOutcome.evaluate`: `arranged` is called only when there is
    /// something to move and somewhere to put it; it returns how many refused.
    pub fn evaluate(enabled: usize, has_display: bool, arranged: impl FnOnce() -> usize) -> ArrangeOutcome {
        if enabled == 0 {
            return ArrangeOutcome::NoWindows;
        }
        if !has_display {
            return ArrangeOutcome::NoDisplay;
        }
        match arranged() {
            0 => ArrangeOutcome::Arranged,
            refused => ArrangeOutcome::Refused { refused, total: enabled },
        }
    }

    /// The phone's `error` reason; `None` only when everything moved. The
    /// first two are the Mac phone-handler strings (`handleArrangeWindows`).
    pub fn message(&self) -> Option<String> {
        match self {
            ArrangeOutcome::Arranged => None,
            ArrangeOutcome::NoWindows => Some("No enabled windows to arrange".into()),
            ArrangeOutcome::NoDisplay => Some("No display available".into()),
            ArrangeOutcome::Refused { refused, total } => {
                Some(format!("Windows refused to move {refused} of {total} windows (elevated or protected)"))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    //! `Shared/Tests/ArrangeLayoutMappingTests.swift`,
    //! `QuipMac/Tests/ArrangeOutcomeTests.swift`, the `LayoutCalculator`
    //! shapes, and the Windows-only border / work-area cases.
    #![allow(non_snake_case)]
    use super::*;

    #[test]
    fn testHorizontalMapsToColumns() {
        assert_eq!(LayoutMode::from_arrange(ArrangeLayout::Horizontal), LayoutMode::Columns);
    }

    #[test]
    fn testVerticalMapsToRows() {
        assert_eq!(LayoutMode::from_arrange(ArrangeLayout::Vertical), LayoutMode::Rows);
    }

    #[test]
    fn testLegacyStringOverloadStillWorks() {
        assert_eq!(LayoutMode::from_arrange_str("horizontal"), Some(LayoutMode::Columns));
        assert_eq!(LayoutMode::from_arrange_str("vertical"), Some(LayoutMode::Rows));
        assert_eq!(LayoutMode::from_arrange_str("grid"), None);
        assert_eq!(LayoutMode::from_arrange_str(""), None);
        assert_eq!(LayoutMode::from_arrange_str("HORIZONTAL"), None);
    }

    #[test]
    fn columns_and_rows_for_one_to_six() {
        for n in 1..=6 {
            let c = calculate(LayoutMode::Columns, n);
            let r = calculate(LayoutMode::Rows, n);
            assert_eq!(c.len(), n);
            for (i, rect) in c.iter().enumerate() {
                assert!((rect.x - i as f64 / n as f64).abs() < 1e-12);
                assert!((rect.width - 1.0 / n as f64).abs() < 1e-12);
                assert_eq!((rect.y, rect.height), (0.0, 1.0));
            }
            for (i, rect) in r.iter().enumerate() {
                assert!((rect.y - i as f64 / n as f64).abs() < 1e-12);
                assert_eq!((rect.x, rect.width), (0.0, 1.0));
            }
        }
    }

    #[test]
    fn zero_windows_is_empty() {
        assert!(calculate(LayoutMode::Columns, 0).is_empty());
        assert!(arrange(ArrangeLayout::Vertical, 0, PixelRect::new(0, 0, 100, 100)).is_empty());
    }

    #[test]
    fn grid_shape_matches_layout_calculator() {
        let g = calculate(LayoutMode::Grid, 5); // 3 cols x 2 rows
        assert_eq!(g.len(), 5);
        assert!((g[3].x - 0.0).abs() < 1e-12 && (g[3].y - 0.5).abs() < 1e-12);
        assert!((g[2].width - 1.0 / 3.0).abs() < 1e-12);
        let g = calculate(LayoutMode::Grid, 4);
        assert!((g[3].x - 0.5).abs() < 1e-12 && (g[3].height - 0.5).abs() < 1e-12);
    }

    #[test]
    fn tiles_touch_and_fill_the_work_area() {
        let area = PixelRect::new(0, 0, 1920, 1040);
        for n in 1..=6 {
            let cols = arrange(ArrangeLayout::Horizontal, n, area);
            assert_eq!(cols[0].x, 0);
            assert_eq!(cols[n - 1].right(), 1920);
            for w in cols.windows(2) {
                assert_eq!(w[0].right(), w[1].x, "no gap, no overlap");
            }
            assert!(cols.iter().all(|r| r.y == 0 && r.height == 1040));
            let rows = arrange(ArrangeLayout::Vertical, n, area);
            assert_eq!(rows[n - 1].bottom(), 1040);
            for w in rows.windows(2) {
                assert_eq!(w[0].bottom(), w[1].y);
            }
        }
    }

    #[test]
    fn pixel_rects_are_within_one_px_of_the_mac_fractional_rects() {
        let area = PixelRect::new(-1920, 0, 1919, 1047);
        for n in 1..=6 {
            for (norm, px) in calculate(LayoutMode::Columns, n).iter().zip(arrange(ArrangeLayout::Horizontal, n, area))
            {
                let mac_x = f64::from(area.x) + norm.x * f64::from(area.width);
                let mac_w = norm.width * f64::from(area.width);
                assert!((f64::from(px.x) - mac_x).abs() <= 1.0);
                assert!((f64::from(px.width) - mac_w).abs() <= 1.0);
            }
        }
    }

    #[test]
    fn work_area_excludes_the_taskbar_on_any_edge() {
        // Bottom, top, left and right taskbars on a 1920x1080 display.
        for area in [
            PixelRect::new(0, 0, 1920, 1040),
            PixelRect::new(0, 40, 1920, 1040),
            PixelRect::new(60, 0, 1860, 1080),
            PixelRect::new(0, 0, 1860, 1080),
        ] {
            for r in
                arrange(ArrangeLayout::Horizontal, 3, area).into_iter().chain(arrange(ArrangeLayout::Vertical, 3, area))
            {
                assert!(
                    r.x >= area.x && r.y >= area.y && r.right() <= area.right() && r.bottom() <= area.bottom(),
                    "{r:?} in {area:?}"
                );
            }
        }
    }

    #[test]
    fn border_compensation_grows_by_each_edge() {
        // Typical Win11: 7 px invisible border left/right/bottom, 0 on top.
        let outer = PixelRect::new(93, 100, 814, 607);
        let visible = PixelRect::new(100, 100, 800, 600);
        let target = PixelRect::new(0, 0, 960, 1040);
        assert_eq!(compensate_border(target, outer, visible), PixelRect::new(-7, 0, 974, 1047));
    }

    #[test]
    fn border_compensation_is_identity_without_a_border() {
        let r = PixelRect::new(10, 20, 30, 40);
        let t = PixelRect::new(1, 2, 3, 4);
        assert_eq!(compensate_border(t, r, r), t);
    }

    #[test]
    fn compensated_neighbours_have_touching_visible_edges() {
        let outer = PixelRect::new(93, 100, 814, 607);
        let visible = PixelRect::new(100, 100, 800, 600);
        let tiles = arrange(ArrangeLayout::Horizontal, 2, PixelRect::new(0, 0, 1920, 1040));
        let a = compensate_border(tiles[0], outer, visible);
        let b = compensate_border(tiles[1], outer, visible);
        // Visible right edge of A = outer right - 7; visible left of B = outer left + 7.
        assert_eq!(a.right() - 7, b.x + 7);
    }

    #[test]
    fn test_noWindows_doesNotAttemptTheMove() {
        let mut calls = 0;
        assert_eq!(
            ArrangeOutcome::evaluate(0, true, || {
                calls += 1;
                0
            }),
            ArrangeOutcome::NoWindows
        );
        assert_eq!(calls, 0);
    }

    #[test]
    fn test_noDisplay_doesNotAttemptTheMove() {
        let mut calls = 0;
        assert_eq!(
            ArrangeOutcome::evaluate(3, false, || {
                calls += 1;
                0
            }),
            ArrangeOutcome::NoDisplay
        );
        assert_eq!(calls, 0);
    }

    #[test]
    fn test_refusedMove_isReported() {
        let mut calls = 0;
        assert_eq!(
            ArrangeOutcome::evaluate(2, true, || {
                calls += 1;
                1
            }),
            ArrangeOutcome::Refused { refused: 1, total: 2 }
        );
        assert_eq!(calls, 1);
    }

    #[test]
    fn test_acceptedMove_isArranged() {
        let mut calls = 0;
        assert_eq!(
            ArrangeOutcome::evaluate(2, true, || {
                calls += 1;
                0
            }),
            ArrangeOutcome::Arranged
        );
        assert_eq!(calls, 1);
    }

    #[test]
    fn test_message_isNilOnlyWhenArranged() {
        assert_eq!(ArrangeOutcome::Arranged.message(), None);
        for o in
            [ArrangeOutcome::NoWindows, ArrangeOutcome::NoDisplay, ArrangeOutcome::Refused { refused: 1, total: 3 }]
        {
            assert!(o.message().is_some(), "{o:?}");
        }
        assert_eq!(
            ArrangeOutcome::Refused { refused: 1, total: 3 }.message().as_deref(),
            Some("Windows refused to move 1 of 3 windows (elevated or protected)")
        );
    }

    #[test]
    fn border_compensation_with_four_different_edges() {
        let outer = PixelRect::new(0, 0, 110, 120);
        let visible = PixelRect::new(3, 5, 100, 100); // left 3, top 5, right 7, bottom 15
        assert_eq!(compensate_border(PixelRect::new(50, 50, 10, 10), outer, visible), PixelRect::new(47, 45, 20, 30));
    }
}
