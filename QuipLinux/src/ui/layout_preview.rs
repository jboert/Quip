use gtk4::prelude::*;
use gtk4::{self};
use std::cell::RefCell;
use std::rc::Rc;

use crate::models::layout::{CustomLayoutTemplate, LayoutCalculator, LayoutMode};
use crate::protocol::types::WindowFrame;
use crate::state::SharedState;

/// Cairo-based layout preview widget showing window arrangement
#[derive(Clone)]
pub struct LayoutPreviewWidget {
    drawing_area: gtk4::DrawingArea,
    shared_state: SharedState,
    layout_mode: Rc<RefCell<LayoutMode>>,
    custom_template: Rc<RefCell<CustomLayoutTemplate>>,
}

impl LayoutPreviewWidget {
    pub fn new(
        shared_state: SharedState,
        layout_mode: Rc<RefCell<LayoutMode>>,
        custom_template: Rc<RefCell<CustomLayoutTemplate>>,
    ) -> Self {
        let drawing_area = gtk4::DrawingArea::new();
        drawing_area.set_content_width(600);
        drawing_area.set_content_height(400);

        let ss = shared_state.clone();
        let lm = layout_mode.clone();
        let ct = custom_template.clone();

        drawing_area.set_draw_func(move |_, cr, width, height| {
            draw_preview(cr, width, height, &ss, &lm.borrow(), &ct.borrow());
        });

        Self {
            drawing_area,
            shared_state,
            layout_mode,
            custom_template,
        }
    }

    pub fn widget(&self) -> &gtk4::DrawingArea {
        &self.drawing_area
    }

    pub fn queue_draw(&self) {
        self.drawing_area.queue_draw();
    }
}

fn draw_preview(
    cr: &cairo::Context,
    width: i32,
    height: i32,
    shared_state: &SharedState,
    layout_mode: &LayoutMode,
    custom_template: &CustomLayoutTemplate,
) {
    let w = width as f64;
    let h = height as f64;

    // Calculate 16:10 preview rect centered in the allocated area
    let margin = 16.0;
    let aspect = 16.0 / 10.0;
    let mut pw = w - margin * 2.0;
    let mut ph = pw / aspect;
    if ph > h - margin * 2.0 {
        ph = h - margin * 2.0;
        pw = ph * aspect;
    }
    let px = (w - pw) / 2.0;
    let py = (h - ph) / 2.0;

    // Monitor background shadow
    cr.set_source_rgba(0.0, 0.0, 0.0, 0.3);
    rounded_rect(cr, px - 2.0, py - 2.0, pw + 4.0, ph + 4.0, 12.0);
    let _ = cr.fill();

    // Monitor background
    cr.set_source_rgb(0.12, 0.12, 0.14);
    rounded_rect(cr, px, py, pw, ph, 8.0);
    let _ = cr.fill();

    // Monitor border
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.1);
    rounded_rect(cr, px, py, pw, ph, 8.0);
    cr.set_line_width(1.0);
    let _ = cr.stroke();

    // Get enabled windows
    let state = shared_state.read().unwrap();
    let enabled: Vec<_> = state.windows.iter().filter(|w| w.is_enabled).collect();
    if enabled.is_empty() {
        // Draw placeholder text
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.3);
        cr.set_font_size(14.0);
        let text = "Enable windows in the sidebar";
        let extents = cr.text_extents(text).unwrap();
        cr.move_to(
            px + (pw - extents.width()) / 2.0,
            py + (ph + extents.height()) / 2.0,
        );
        let _ = cr.show_text(text);
        return;
    }

    // Calculate frames
    let frames = match layout_mode {
        LayoutMode::Custom => custom_template.frames(enabled.len()),
        _ => LayoutCalculator::calculate(*layout_mode, enabled.len()),
    };

    let gap = 3.0;

    // Draw each window tile
    for (i, window) in enabled.iter().enumerate() {
        if i >= frames.len() {
            break;
        }
        let frame = &frames[i];
        let (r, g, b) = hex_to_rgb(&window.assigned_color);

        let tile_x = px + frame.x * pw + gap;
        let tile_y = py + frame.y * ph + gap;
        let tile_w = frame.width * pw - gap * 2.0;
        let tile_h = frame.height * ph - gap * 2.0;

        // Fill
        cr.set_source_rgba(r, g, b, 0.2);
        rounded_rect(cr, tile_x, tile_y, tile_w, tile_h, 6.0);
        let _ = cr.fill();

        // Border
        cr.set_source_rgba(r, g, b, 0.8);
        rounded_rect(cr, tile_x, tile_y, tile_w, tile_h, 6.0);
        cr.set_line_width(2.0);
        let _ = cr.stroke();

        // Window name label
        cr.set_source_rgba(r, g, b, 1.0);
        cr.set_font_size(11.0);
        let name = &window.name;
        let max_chars = (tile_w / 7.0) as usize;
        let display_name = if name.len() > max_chars && max_chars > 3 {
            format!("{}...", &name[..max_chars - 3])
        } else {
            name.clone()
        };
        if let Ok(extents) = cr.text_extents(&display_name) {
            let tx = tile_x + (tile_w - extents.width()) / 2.0;
            let ty = tile_y + (tile_h + extents.height()) / 2.0;
            cr.move_to(tx, ty);
            let _ = cr.show_text(&display_name);
        }

        // Subtitle
        if tile_h > 40.0 {
            let sub = if window.subtitle.is_empty() { &window.app } else { &window.subtitle };
            cr.set_source_rgba(1.0, 1.0, 1.0, 0.4);
            cr.set_font_size(9.0);
            if let Ok(extents) = cr.text_extents(sub) {
                let tx = tile_x + (tile_w - extents.width()) / 2.0;
                let ty = tile_y + (tile_h + extents.height()) / 2.0 + 14.0;
                cr.move_to(tx, ty);
                let _ = cr.show_text(sub);
            }
        }
    }
}

fn rounded_rect(cr: &cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    let pi = std::f64::consts::PI;
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -pi / 2.0, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, pi / 2.0);
    cr.arc(x + r, y + h - r, r, pi / 2.0, pi);
    cr.arc(x + r, y + r, r, pi, 3.0 * pi / 2.0);
    cr.close_path();
}

fn hex_to_rgb(hex: &str) -> (f64, f64, f64) {
    let hex = hex.trim_start_matches('#');
    if hex.len() < 6 {
        return (0.5, 0.5, 0.5);
    }
    let r = u8::from_str_radix(&hex[0..2], 16).unwrap_or(128) as f64 / 255.0;
    let g = u8::from_str_radix(&hex[2..4], 16).unwrap_or(128) as f64 / 255.0;
    let b = u8::from_str_radix(&hex[4..6], 16).unwrap_or(128) as f64 / 255.0;
    (r, g, b)
}
