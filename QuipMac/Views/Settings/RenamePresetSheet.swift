// RenamePresetSheet.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

// MARK: - Rename Preset Sheet

struct RenamePresetSheet: View {
    let preset: SavedLayoutPreset
    let onRename: (String) -> Void

    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(preset: SavedLayoutPreset, onRename: @escaping (String) -> Void) {
        self.preset = preset
        self.onRename = onRename
        self._name = State(initialValue: preset.name)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Layout")
                .font(.headline)

            TextField("Layout name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Rename") {
                    onRename(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}
