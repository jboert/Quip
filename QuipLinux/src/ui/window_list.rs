use gtk4::prelude::*;
use gtk4::{self, Align, Orientation};
use std::cell::RefCell;
use std::sync::Arc;

use crate::platform::traits::InputBackend;
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
    pub fn new(shared_state: SharedState, input_backend: Arc<dyn InputBackend>) -> Self {
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

        // Add session button (+)
        let add_button = gtk4::Button::from_icon_name("list-add-symbolic");
        add_button.set_tooltip_text(Some("New Claude session in tmux"));
        add_button.add_css_class("flat");

        let ss_add = shared_state.clone();
        let ib_add = input_backend.clone();
        add_button.connect_clicked(move |btn| {
            // Remove any previous popover
            if let Some(prev) = btn.first_child() {
                if prev.is::<gtk4::Popover>() {
                    prev.unparent();
                }
            }

            let state = ss_add.read().unwrap();
            let terminal = state.settings.general.default_terminal.clone();
            let projects = state.settings.directories.projects.clone();
            drop(state);

            let vbox = gtk4::Box::new(Orientation::Vertical, 4);
            vbox.set_margin_start(8);
            vbox.set_margin_end(8);
            vbox.set_margin_top(8);
            vbox.set_margin_bottom(8);

            if projects.is_empty() {
                let label = gtk4::Label::new(Some("No project directories configured.\nAdd them in Settings."));
                label.add_css_class("dim-label");
                label.add_css_class("caption");
                vbox.append(&label);
            } else {
                let label = gtk4::Label::new(Some("Open Claude in:"));
                label.add_css_class("heading");
                label.set_halign(Align::Start);
                vbox.append(&label);

                for dir in &projects {
                    let dir_name = std::path::Path::new(dir)
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or(dir)
                        .to_string();

                    let item_btn = gtk4::Button::new();
                    let btn_box = gtk4::Box::new(Orientation::Horizontal, 8);
                    let icon = gtk4::Image::from_icon_name("folder-symbolic");
                    icon.add_css_class("dim-label");
                    btn_box.append(&icon);
                    let lbl = gtk4::Label::new(Some(&dir_name));
                    lbl.set_halign(Align::Start);
                    btn_box.append(&lbl);
                    item_btn.set_child(Some(&btn_box));
                    item_btn.add_css_class("flat");

                    let dir_clone = dir.clone();
                    let term_clone = terminal.clone();
                    let ib_clone = ib_add.clone();
                    item_btn.connect_clicked(move |b| {
                        if let Err(e) = ib_clone.spawn_terminal(&term_clone, &dir_clone) {
                            tracing::warn!("Failed to spawn terminal: {e}");
                        }
                        if let Some(popover) = b.ancestor(gtk4::Popover::static_type()) {
                            if let Ok(p) = popover.downcast::<gtk4::Popover>() {
                                p.popdown();
                            }
                        }
                    });
                    vbox.append(&item_btn);
                }
            }

            let popover = gtk4::Popover::new();
            popover.set_parent(btn);
            popover.set_child(Some(&vbox));
            popover.popup();
        });

        bottom.append(&add_button);

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

        // Herd terminal windows up to the top so Claude sessions aren't
        // buried under browser windows and whatnot. Within each group the
        // user's custom order is preserved. Mirrors the Mac sidebar.
        let (terminals, others): (Vec<_>, Vec<_>) = state.windows.iter()
            .partition(|w| crate::platform::traits::is_terminal_class(&w.app_class));
        for (i, window) in terminals.iter().chain(others.iter()).enumerate() {
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

        // Name + subtitle. Primary label is the folder/project when known,
        // else the app name — rendered bold in the window's palette color so
        // it doubles as the visual identifier of the selection. Secondary is
        // the app name when a folder sits above, otherwise the window title.
        let text_box = gtk4::Box::new(Orientation::Vertical, 1);
        text_box.set_hexpand(true);

        let has_folder = !window.subtitle.is_empty();
        let primary_text = if has_folder { &window.subtitle } else { &window.app };
        let secondary_text = if has_folder { &window.app } else { &window.name };

        let (pr, pg, pb) = hex_to_rgb(&window.assigned_color);
        let primary_markup = format!(
            "<span color=\"#{:02x}{:02x}{:02x}\" weight=\"bold\">{}</span>",
            (pr * 255.0) as u8,
            (pg * 255.0) as u8,
            (pb * 255.0) as u8,
            glib::markup_escape_text(primary_text)
        );
        let primary_label = gtk4::Label::new(None);
        primary_label.set_markup(&primary_markup);
        primary_label.set_halign(Align::Start);
        primary_label.set_ellipsize(pango::EllipsizeMode::End);
        primary_label.set_max_width_chars(30);
        text_box.append(&primary_label);

        let secondary_label = gtk4::Label::new(Some(secondary_text));
        secondary_label.set_halign(Align::Start);
        secondary_label.add_css_class("dim-label");
        secondary_label.add_css_class("caption");
        secondary_label.set_ellipsize(pango::EllipsizeMode::End);
        text_box.append(&secondary_label);

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
