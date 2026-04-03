use crate::protocol::types::WindowFrame;

/// Layout mode — matches Mac's LayoutMode enum
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayoutMode {
    Columns,
    Rows,
    Grid,
    Custom,
}

impl LayoutMode {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Columns => "Columns",
            Self::Rows => "Rows",
            Self::Grid => "Grid",
            Self::Custom => "Custom",
        }
    }

    pub const ALL: &[LayoutMode] = &[
        LayoutMode::Columns,
        LayoutMode::Rows,
        LayoutMode::Grid,
        LayoutMode::Custom,
    ];
}

/// Custom layout template presets
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CustomLayoutTemplate {
    LargeLeftSmallRight,
    LargeTopSmallBottom,
    TwoLargeSmallRight,
}

impl CustomLayoutTemplate {
    pub fn label(&self) -> &'static str {
        match self {
            Self::LargeLeftSmallRight => "Large + Right Stack",
            Self::LargeTopSmallBottom => "Large + Bottom Stack",
            Self::TwoLargeSmallRight => "Two Large + Right Column",
        }
    }

    pub const ALL: &[CustomLayoutTemplate] = &[
        CustomLayoutTemplate::LargeLeftSmallRight,
        CustomLayoutTemplate::LargeTopSmallBottom,
        CustomLayoutTemplate::TwoLargeSmallRight,
    ];

    pub fn frames(&self, count: usize) -> Vec<WindowFrame> {
        if count == 0 {
            return vec![];
        }
        match self {
            Self::LargeLeftSmallRight => {
                if count == 1 {
                    return vec![WindowFrame { x: 0.0, y: 0.0, width: 1.0, height: 1.0 }];
                }
                let small_count = count - 1;
                let small_height = 1.0 / small_count as f64;
                let mut rects = vec![WindowFrame { x: 0.0, y: 0.0, width: 0.6, height: 1.0 }];
                for i in 0..small_count {
                    rects.push(WindowFrame {
                        x: 0.6,
                        y: i as f64 * small_height,
                        width: 0.4,
                        height: small_height,
                    });
                }
                rects
            }
            Self::LargeTopSmallBottom => {
                if count == 1 {
                    return vec![WindowFrame { x: 0.0, y: 0.0, width: 1.0, height: 1.0 }];
                }
                let small_count = count - 1;
                let small_width = 1.0 / small_count as f64;
                let mut rects = vec![WindowFrame { x: 0.0, y: 0.0, width: 1.0, height: 0.6 }];
                for i in 0..small_count {
                    rects.push(WindowFrame {
                        x: i as f64 * small_width,
                        y: 0.6,
                        width: small_width,
                        height: 0.4,
                    });
                }
                rects
            }
            Self::TwoLargeSmallRight => {
                if count <= 2 {
                    return LayoutCalculator::calculate(LayoutMode::Columns, count);
                }
                let small_count = count - 2;
                let small_height = 1.0 / small_count as f64;
                let mut rects = vec![
                    WindowFrame { x: 0.0, y: 0.0, width: 0.35, height: 1.0 },
                    WindowFrame { x: 0.35, y: 0.0, width: 0.35, height: 1.0 },
                ];
                for i in 0..small_count {
                    rects.push(WindowFrame {
                        x: 0.7,
                        y: i as f64 * small_height,
                        width: 0.3,
                        height: small_height,
                    });
                }
                rects
            }
        }
    }
}

/// Calculate layout frames for a given mode and window count
pub struct LayoutCalculator;

impl LayoutCalculator {
    pub fn calculate(mode: LayoutMode, window_count: usize) -> Vec<WindowFrame> {
        if window_count == 0 {
            return vec![];
        }
        match mode {
            LayoutMode::Columns => Self::columns(window_count),
            LayoutMode::Rows => Self::rows(window_count),
            LayoutMode::Grid => Self::grid(window_count),
            LayoutMode::Custom => Self::grid(window_count),
        }
    }

    fn columns(count: usize) -> Vec<WindowFrame> {
        let width = 1.0 / count as f64;
        (0..count)
            .map(|i| WindowFrame {
                x: i as f64 * width,
                y: 0.0,
                width,
                height: 1.0,
            })
            .collect()
    }

    fn rows(count: usize) -> Vec<WindowFrame> {
        let height = 1.0 / count as f64;
        (0..count)
            .map(|i| WindowFrame {
                x: 0.0,
                y: i as f64 * height,
                width: 1.0,
                height,
            })
            .collect()
    }

    fn grid(count: usize) -> Vec<WindowFrame> {
        let cols = (count as f64).sqrt().ceil() as usize;
        let rows = (count as f64 / cols as f64).ceil() as usize;
        let cell_width = 1.0 / cols as f64;
        let cell_height = 1.0 / rows as f64;
        (0..count)
            .map(|i| {
                let col = i % cols;
                let row = i / cols;
                WindowFrame {
                    x: col as f64 * cell_width,
                    y: row as f64 * cell_height,
                    width: cell_width,
                    height: cell_height,
                }
            })
            .collect()
    }
}
