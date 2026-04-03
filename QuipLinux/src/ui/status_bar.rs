use gtk4::prelude::*;
use gtk4::{self, Align, Orientation};

use crate::state::SharedState;

/// Bottom status bar showing connection state, client count, and tunnel URL
#[derive(Clone)]
pub struct StatusBar {
    container: gtk4::Box,
    status_dot: gtk4::DrawingArea,
    status_label: gtk4::Label,
    tunnel_label: gtk4::Label,
    shared_state: SharedState,
}

impl StatusBar {
    pub fn new(shared_state: SharedState) -> Self {
        let container = gtk4::Box::new(Orientation::Horizontal, 8);
        container.set_margin_start(16);
        container.set_margin_end(16);
        container.set_margin_top(8);
        container.set_margin_bottom(8);

        // Connection status dot
        let status_dot = gtk4::DrawingArea::new();
        status_dot.set_content_width(8);
        status_dot.set_content_height(8);
        status_dot.set_valign(Align::Center);
        status_dot.set_draw_func(|_, cr, w, h| {
            cr.arc(w as f64 / 2.0, h as f64 / 2.0, 4.0, 0.0, 2.0 * std::f64::consts::PI);
            cr.set_source_rgb(0.3, 0.7, 0.3); // green
            let _ = cr.fill();
        });
        container.append(&status_dot);

        let status_label = gtk4::Label::new(Some("Listening"));
        status_label.add_css_class("dim-label");
        status_label.add_css_class("caption");
        container.append(&status_label);

        // Spacer
        let spacer = gtk4::Box::new(Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        container.append(&spacer);

        // Tunnel status
        let tunnel_label = gtk4::Label::new(Some("Tunnel starting..."));
        tunnel_label.add_css_class("dim-label");
        tunnel_label.add_css_class("caption");
        tunnel_label.set_selectable(true);
        container.append(&tunnel_label);

        let widget = Self {
            container,
            status_dot,
            status_label,
            tunnel_label,
            shared_state,
        };

        widget.refresh();
        widget
    }

    pub fn widget(&self) -> &gtk4::Box {
        &self.container
    }

    pub fn refresh(&self) {
        let state = self.shared_state.read().unwrap();

        // Connection status
        let is_green = state.ws_running;
        self.status_dot.set_draw_func(move |_, cr, w, h| {
            cr.arc(w as f64 / 2.0, h as f64 / 2.0, 4.0, 0.0, 2.0 * std::f64::consts::PI);
            if is_green {
                cr.set_source_rgb(0.3, 0.7, 0.3);
            } else {
                cr.set_source_rgb(0.7, 0.3, 0.3);
            }
            let _ = cr.fill();
        });
        self.status_dot.queue_draw();

        if state.ws_client_count > 0 {
            let n = state.ws_client_count;
            let s = if n == 1 { "" } else { "s" };
            self.status_label.set_text(&format!("{n} client{s}"));
        } else if state.ws_running {
            self.status_label.set_text("Listening");
        } else {
            self.status_label.set_text("Offline");
        }

        // Tunnel status
        if !state.tunnel_ws_url.is_empty() {
            self.tunnel_label.set_text(&state.tunnel_ws_url);
        } else if state.tunnel_running {
            self.tunnel_label.set_text("Tunnel starting...");
        } else {
            self.tunnel_label.set_text("Tunnel offline");
        }
    }
}
