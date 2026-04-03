use gtk4::prelude::*;
use gtk4::{self, Align, Orientation};
use std::cell::RefCell;
use std::rc::Rc;

use crate::state::SharedState;

/// Sidebar widget showing a list of managed windows with checkboxes
#[derive(Clone)]
pub struct WindowListWidget {
    container: gtk4::Box,
    list_box: gtk4::ListBox,
    scrolled: gtk4::ScrolledWindow,
    count_label: gtk4::Label,
    shared_state: SharedState,
    last_fingerprint: RefCell<String>,
}

impl WindowListWidget {
    pub fn new(shared_state: SharedState) -> Self {
        let container = gtk4::Box::new(Orientation::Vertical, 0);

        // Header
        let header = gtk4::Box::new(Orientation::Horizontal, 8);
        header.set_margin_start(16);
        header.set_margin_end(16);
        header.set_margin_top(10);
        header.set_margin_bottom(10);

        let title = gtk4::Label::new(Some("Windows"));
        title.add_css_class("heading");
        header.append(&title);

        let count_label = gtk4::Label::new(Some("(0)"));
        count_label.add_css_class("dim-label");
        header.append(&count_label);

        let spacer = gtk4::Box::new(Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        header.append(&spacer);

        container.append(&header);
        container.append(&gtk4::Separator::new(Orientation::Horizontal));

        // Scrollable list
        let scrolled = gtk4::ScrolledWindow::new();
        scrolled.set_vexpand(true);
        scrolled.set_policy(gtk4::PolicyType::Never, gtk4::PolicyType::Automatic);

        let list_box = gtk4::ListBox::new();
        list_box.set_selection_mode(gtk4::SelectionMode::Single);
        list_box.add_css_class("navigation-sidebar");
        scrolled.set_child(Some(&list_box));
        container.append(&scrolled);

        container.append(&gtk4::Separator::new(Orientation::Horizontal));

        // Bottom bar
        let bottom = gtk4::Box::new(Orientation::Horizontal, 8);
        bottom.set_margin_start(16);
        bottom.set_margin_end(16);
        bottom.set_margin_top(8);
        bottom.set_margin_bottom(8);

        let refresh_button = gtk4::Button::from_icon_name("view-refresh-symbolic");
        refresh_button.set_tooltip_text(Some("Refresh window list"));
        bottom.append(&refresh_button);

        container.append(&bottom);

        let widget = Self {
            container,
            list_box,
            scrolled,
            count_label,
            shared_state,
            last_fingerprint: RefCell::new(String::new()),
        };

        widget.populate();
        widget
    }

    pub fn container(&self) -> &gtk4::Box {
        &self.container
    }

    pub fn refresh(&self) {
        let state = self.shared_state.read().unwrap();

        // Build a fingerprint of the current window list to avoid unnecessary rebuilds
        // (rebuilding resets scroll position)
        let fingerprint = state.windows.iter()
            .map(|w| format!("{}:{}:{}", w.id, w.name, w.is_enabled))
            .collect::<Vec<_>>()
            .join("|");

        self.count_label.set_text(&format!("({})", state.windows.len()));

        if *self.last_fingerprint.borrow() == fingerprint {
            return;
        }
        *self.last_fingerprint.borrow_mut() = fingerprint;

        drop(state);
        self.populate();
    }

    fn populate(&self) {
        // Remove all existing rows
        while let Some(child) = self.list_box.first_child() {
            self.list_box.remove(&child);
        }

        let state = self.shared_state.read().unwrap();

        for (i, window) in state.windows.iter().enumerate() {
            let row = self.build_row(window, i);
            self.list_box.append(&row);
        }
    }

    fn build_row(&self, window: &crate::models::managed_window::ManagedWindow, index: usize) -> gtk4::ListBoxRow {
        let row = gtk4::ListBoxRow::new();
        let hbox = gtk4::Box::new(Orientation::Horizontal, 8);
        hbox.set_margin_start(8);
        hbox.set_margin_end(8);
        hbox.set_margin_top(4);
        hbox.set_margin_bottom(4);

        // Checkbox
        let check = gtk4::CheckButton::new();
        check.set_active(window.is_enabled);
        let ss = self.shared_state.clone();
        let wid = window.id.clone();
        check.connect_toggled(move |btn| {
            let mut state = ss.write().unwrap();
            state.toggle_window(&wid, btn.is_active());
        });
        hbox.append(&check);

        // Index number
        let idx_label = gtk4::Label::new(Some(&format!("{}.", index + 1)));
        idx_label.add_css_class("dim-label");
        idx_label.add_css_class("monospace");
        hbox.append(&idx_label);

        // Color dot (using a small drawing area)
        let color_dot = gtk4::DrawingArea::new();
        color_dot.set_content_width(10);
        color_dot.set_content_height(10);
        let color_hex = window.assigned_color.clone();
        color_dot.set_draw_func(move |_, cr, w, h| {
            let (r, g, b) = hex_to_rgb(&color_hex);
            cr.arc(w as f64 / 2.0, h as f64 / 2.0, 5.0, 0.0, 2.0 * std::f64::consts::PI);
            cr.set_source_rgb(r, g, b);
            let _ = cr.fill();
        });
        color_dot.set_valign(Align::Center);
        hbox.append(&color_dot);

        // Name + subtitle
        let text_box = gtk4::Box::new(Orientation::Vertical, 1);
        text_box.set_hexpand(true);

        let name_label = gtk4::Label::new(Some(&window.name));
        name_label.set_halign(Align::Start);
        name_label.set_ellipsize(pango::EllipsizeMode::End);
        name_label.set_max_width_chars(30);
        text_box.append(&name_label);

        let sub_text = if window.subtitle.is_empty() { &window.app } else { &window.subtitle };
        let sub_label = gtk4::Label::new(Some(sub_text));
        sub_label.set_halign(Align::Start);
        sub_label.add_css_class("dim-label");
        sub_label.add_css_class("caption");
        sub_label.set_ellipsize(pango::EllipsizeMode::End);
        text_box.append(&sub_label);

        hbox.append(&text_box);

        // Opacity for disabled
        if !window.is_enabled {
            hbox.set_opacity(0.5);
        }

        row.set_child(Some(&hbox));
        row
    }
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
