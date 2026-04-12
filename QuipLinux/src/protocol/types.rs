use serde::{Deserialize, Serialize};

/// Terminal state — matches Mac's TerminalState enum
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TerminalState {
    #[serde(rename = "neutral")]
    Neutral,
    #[serde(rename = "waiting_for_input")]
    WaitingForInput,
    #[serde(rename = "stt_active")]
    SttActive,
}

impl Default for TerminalState {
    fn default() -> Self {
        Self::Neutral
    }
}

impl TerminalState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Neutral => "neutral",
            Self::WaitingForInput => "waiting_for_input",
            Self::SttActive => "stt_active",
        }
    }
}

/// Normalized window frame in 0.0-1.0 coordinate space
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct WindowFrame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Absolute pixel rectangle
#[derive(Debug, Clone, Copy, Default)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

impl Rect {
    pub fn from_normalized(frame: &WindowFrame, screen: &Rect) -> Self {
        Rect {
            x: screen.x + (frame.x * screen.width as f64) as i32,
            y: screen.y + (frame.y * screen.height as f64) as i32,
            width: (frame.width * screen.width as f64) as u32,
            height: (frame.height * screen.height as f64) as u32,
        }
    }

    pub fn to_normalized(&self, screen: &Rect) -> WindowFrame {
        if screen.width == 0 || screen.height == 0 {
            return WindowFrame {
                x: 0.0,
                y: 0.0,
                width: 1.0,
                height: 1.0,
            };
        }
        // Clamp to [0,1]: a window may physically extend past the usable
        // screen area (e.g. after the desktop panel reappears and the
        // reported screen shrinks). Raw >1 values make the phone layout
        // overflow past its viewport buttons in portrait.
        let x = (((self.x - screen.x) as f64) / screen.width as f64).clamp(0.0, 1.0);
        let y = (((self.y - screen.y) as f64) / screen.height as f64).clamp(0.0, 1.0);
        let width = (self.width as f64 / screen.width as f64).clamp(0.0, 1.0 - x);
        let height = (self.height as f64 / screen.height as f64).clamp(0.0, 1.0 - y);
        WindowFrame { x, y, width, height }
    }

    pub fn center_x(&self) -> i32 {
        self.x + self.width as i32 / 2
    }

    pub fn center_y(&self) -> i32 {
        self.y + self.height as i32 / 2
    }

    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x as f64
            && px <= (self.x + self.width as i32) as f64
            && py >= self.y as f64
            && py <= (self.y + self.height as i32) as f64
    }
}
