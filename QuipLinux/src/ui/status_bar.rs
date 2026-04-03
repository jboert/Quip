use gtk4::prelude::*;
use gtk4::{self, Align, Orientation};
use gdk4::Display;
use gdk_pixbuf;

use crate::state::SharedState;

/// Bottom status bar matching the Mac app layout:
/// [status dot + label]  [spacer]  [globe + url + copy + qr]
#[derive(Clone)]
pub struct StatusBar {
    container: gtk4::Box,
    status_dot: gtk4::DrawingArea,
    status_label: gtk4::Label,
    globe_icon: gtk4::Image,
    url_label: gtk4::Label,
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

        // ── Left: connection status ────────────────────────────────────
        let status_dot = gtk4::DrawingArea::new();
        status_dot.set_content_width(8);
        status_dot.set_content_height(8);
        status_dot.set_valign(Align::Center);
        status_dot.set_draw_func(|_, cr, w, h| {
            cr.arc(w as f64 / 2.0, h as f64 / 2.0, 4.0, 0.0, 2.0 * std::f64::consts::PI);
            cr.set_source_rgb(0.3, 0.7, 0.3);
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

        // ── Right: globe + URL + copy + QR ─────────────────────────────
        let globe_icon = gtk4::Image::from_icon_name("network-server-symbolic");
        globe_icon.set_valign(Align::Center);
        globe_icon.add_css_class("dim-label");
        container.append(&globe_icon);

        let url_label = gtk4::Label::new(None);
        url_label.add_css_class("dim-label");
        url_label.add_css_class("caption");
        url_label.add_css_class("monospace");
        url_label.set_selectable(true);
        container.append(&url_label);

        // Copy button
        let copy_button = gtk4::Button::from_icon_name("edit-copy-symbolic");
        copy_button.set_tooltip_text(Some("Copy connection URL"));
        copy_button.set_valign(Align::Center);
        copy_button.add_css_class("flat");
        let ss_copy = shared_state.clone();
        copy_button.connect_clicked(move |_| {
            let url = Self::best_url(&ss_copy);
            if !url.is_empty() {
                if let Some(display) = Display::default() {
                    display.clipboard().set_text(&url);
                }
            }
        });
        container.append(&copy_button);

        // QR code button
        let qr_button = gtk4::Button::from_icon_name("view-barcode-qr-symbolic");
        qr_button.set_tooltip_text(Some("Show QR code for phone"));
        qr_button.set_valign(Align::Center);
        qr_button.add_css_class("flat");
        let ss_qr = shared_state.clone();
        qr_button.connect_clicked(move |btn| {
            let url = Self::best_url(&ss_qr);
            tracing::info!("QR button clicked, url={url}");
            if !url.is_empty() {
                show_qr_popover(btn, &url);
            }
        });
        container.append(&qr_button);

        let widget = Self {
            container,
            status_dot,
            status_label,
            globe_icon,
            url_label,
            copy_button,
            qr_button,
            shared_state,
        };

        widget.refresh();
        widget
    }

    /// Return the best available URL: tunnel URL if available, otherwise local WS address.
    fn best_url(shared_state: &SharedState) -> String {
        let state = shared_state.read().unwrap();
        if !state.tunnel_ws_url.is_empty() {
            state.tunnel_ws_url.clone()
        } else if state.ws_running {
            let ip = local_ipv4().unwrap_or_else(|| "localhost".into());
            format!("ws://{}:{}", ip, state.settings.general.websocket_port)
        } else {
            String::new()
        }
    }

    pub fn widget(&self) -> &gtk4::Box {
        &self.container
    }

    pub fn refresh(&self) {
        let state = self.shared_state.read().unwrap();

        // ── Connection status (left side) ──────────────────────────────
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

        // ── URL display (right side) ───────────────────────────────────
        let has_tunnel = !state.tunnel_ws_url.is_empty();

        if has_tunnel {
            self.globe_icon.set_icon_name(Some("network-server-symbolic"));
            self.globe_icon.remove_css_class("error");
            self.globe_icon.add_css_class("success");
            self.url_label.set_text(&state.tunnel_ws_url);
        } else if state.tunnel_running {
            self.globe_icon.remove_css_class("error");
            self.globe_icon.remove_css_class("success");
            self.url_label.set_text("Starting tunnel...");
        } else if state.ws_running {
            // No tunnel, but WS is running — show local address
            let ip = local_ipv4().unwrap_or_else(|| "localhost".into());
            let local_url = format!("ws://{}:{}", ip, state.settings.general.websocket_port);
            self.globe_icon.set_icon_name(Some("network-wired-symbolic"));
            self.globe_icon.remove_css_class("error");
            self.globe_icon.remove_css_class("success");
            self.url_label.set_text(&local_url);
        } else {
            self.globe_icon.set_icon_name(Some("network-offline-symbolic"));
            self.globe_icon.add_css_class("error");
            self.globe_icon.remove_css_class("success");
            self.url_label.set_text("Offline");
        }

        // Always show copy/QR when we have any URL
        let has_any_url = has_tunnel || state.ws_running;
        self.copy_button.set_visible(has_any_url);
        self.qr_button.set_visible(has_any_url);
    }
}

/// Get the first non-loopback IPv4 address.
fn local_ipv4() -> Option<String> {
    if_addrs::get_if_addrs().ok()?.into_iter()
        .find(|iface| !iface.is_loopback() && iface.addr.ip().is_ipv4())
        .map(|iface| iface.addr.ip().to_string())
}

fn show_qr_popover(parent: &gtk4::Button, url: &str) {
    // Unparent any existing popover to avoid GTK warnings
    if let Some(prev) = parent.first_child() {
        if prev.is::<gtk4::Popover>() {
            prev.unparent();
        }
    }

    let popover = gtk4::Popover::new();
    popover.set_parent(parent);

    let vbox = gtk4::Box::new(Orientation::Vertical, 12);
    vbox.set_margin_start(16);
    vbox.set_margin_end(16);
    vbox.set_margin_top(16);
    vbox.set_margin_bottom(16);

    let title = gtk4::Label::new(Some("Scan with phone"));
    title.add_css_class("heading");
    vbox.append(&title);

    // Generate QR code
    if let Some(pixbuf) = generate_qr_pixbuf(url) {
        let texture = gdk4::Texture::for_pixbuf(&pixbuf);
        let image = gtk4::Picture::for_paintable(&texture);
        image.set_size_request(200, 200);
        vbox.append(&image);
    }

    let url_box = gtk4::Box::new(Orientation::Horizontal, 8);
    url_box.set_halign(Align::Center);

    let url_label = gtk4::Label::new(Some(url));
    url_label.add_css_class("caption");
    url_label.add_css_class("monospace");
    url_label.set_selectable(true);
    url_label.set_wrap(true);
    url_label.set_max_width_chars(30);
    url_box.append(&url_label);

    let url_for_copy = url.to_string();
    let copy_btn = gtk4::Button::from_icon_name("edit-copy-symbolic");
    copy_btn.add_css_class("flat");
    copy_btn.set_tooltip_text(Some("Copy URL"));
    copy_btn.connect_clicked(move |_| {
        if let Some(display) = Display::default() {
            display.clipboard().set_text(&url_for_copy);
        }
    });
    url_box.append(&copy_btn);

    vbox.append(&url_box);

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
