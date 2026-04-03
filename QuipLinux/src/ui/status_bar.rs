use gtk4::prelude::*;
use gtk4::{self, Align, Orientation};
use gdk4::Display;
use gdk_pixbuf;

use crate::state::SharedState;

/// Bottom status bar showing connection state, client count, tunnel URL, copy button, and QR button
#[derive(Clone)]
pub struct StatusBar {
    container: gtk4::Box,
    status_dot: gtk4::DrawingArea,
    status_label: gtk4::Label,
    tunnel_label: gtk4::Label,
    copy_button: gtk4::Button,
    qr_button: gtk4::Button,
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

        // Copy button
        let copy_button = gtk4::Button::from_icon_name("edit-copy-symbolic");
        copy_button.set_tooltip_text(Some("Copy tunnel URL"));
        copy_button.set_valign(Align::Center);
        copy_button.add_css_class("flat");
        copy_button.set_visible(false);
        let ss_copy = shared_state.clone();
        copy_button.connect_clicked(move |_| {
            let state = ss_copy.read().unwrap();
            if !state.tunnel_ws_url.is_empty() {
                if let Some(display) = Display::default() {
                    let clipboard = display.clipboard();
                    clipboard.set_text(&state.tunnel_ws_url);
                }
            }
        });
        container.append(&copy_button);

        // QR code button
        let qr_button = gtk4::Button::from_icon_name("camera-photo-symbolic");
        qr_button.set_tooltip_text(Some("Show QR code for iPhone"));
        qr_button.set_valign(Align::Center);
        qr_button.add_css_class("flat");
        qr_button.set_visible(false);
        let ss_qr = shared_state.clone();
        qr_button.connect_clicked(move |btn| {
            let state = ss_qr.read().unwrap();
            let url = state.tunnel_ws_url.clone();
            drop(state);
            if !url.is_empty() {
                show_qr_popover(btn, &url);
            }
        });
        container.append(&qr_button);

        let widget = Self {
            container,
            status_dot,
            status_label,
            tunnel_label,
            copy_button,
            qr_button,
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
        let has_url = !state.tunnel_ws_url.is_empty();
        if has_url {
            self.tunnel_label.set_text(&state.tunnel_ws_url);
        } else if state.tunnel_running {
            self.tunnel_label.set_text("Tunnel starting...");
        } else {
            self.tunnel_label.set_text("Tunnel offline");
        }

        self.copy_button.set_visible(has_url);
        self.qr_button.set_visible(has_url);
    }
}

fn show_qr_popover(parent: &gtk4::Button, url: &str) {
    let popover = gtk4::Popover::new();
    popover.set_parent(parent);

    let vbox = gtk4::Box::new(Orientation::Vertical, 12);
    vbox.set_margin_start(16);
    vbox.set_margin_end(16);
    vbox.set_margin_top(16);
    vbox.set_margin_bottom(16);

    let title = gtk4::Label::new(Some("Scan with iPhone"));
    title.add_css_class("heading");
    vbox.append(&title);

    // Generate QR code
    if let Some(pixbuf) = generate_qr_pixbuf(url) {
        let texture = gdk4::Texture::for_pixbuf(&pixbuf);
        let image = gtk4::Picture::for_paintable(&texture);
        image.set_size_request(200, 200);
        vbox.append(&image);
    }

    let url_label = gtk4::Label::new(Some(url));
    url_label.add_css_class("caption");
    url_label.add_css_class("monospace");
    url_label.set_selectable(true);
    url_label.set_wrap(true);
    url_label.set_max_width_chars(30);
    vbox.append(&url_label);

    popover.set_child(Some(&vbox));
    popover.popup();
}

fn generate_qr_pixbuf(data: &str) -> Option<gdk_pixbuf::Pixbuf> {
    use qrcode::QrCode;
    use qrcode::types::Color;

    let code = QrCode::new(data.as_bytes()).ok()?;
    let modules = code.to_colors();
    let width = code.width();
    let scale = 4;
    let border = 2;
    let img_size = (width + border * 2) * scale;

    let mut pixels = vec![255u8; (img_size * img_size * 3) as usize];

    for y in 0..width {
        for x in 0..width {
            let color = modules[y * width + x];
            if color == Color::Dark {
                for dy in 0..scale {
                    for dx in 0..scale {
                        let px = ((x + border) * scale + dx) as usize;
                        let py = ((y + border) * scale + dy) as usize;
                        let idx = (py * img_size as usize + px) * 3;
                        pixels[idx] = 0;
                        pixels[idx + 1] = 0;
                        pixels[idx + 2] = 0;
                    }
                }
            }
        }
    }

    gdk_pixbuf::Pixbuf::from_bytes(
        &glib::Bytes::from_owned(pixels),
        gdk_pixbuf::Colorspace::Rgb,
        false,
        8,
        img_size as i32,
        img_size as i32,
        (img_size * 3) as i32,
    ).into()
}
