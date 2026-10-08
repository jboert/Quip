// LayoutsTab.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

// MARK: - Layouts Tab

struct LayoutsTab: View {
    @AppStorage("savedPresets") private var savedPresetsData: Data = Data()
    @State private var presets: [SavedLayoutPreset] = []
    @State private var editingPreset: SavedLayoutPreset?

    var body: some View {
        VStack(spacing: 0) {
            if presets.isEmpty {
                ContentUnavailableView(
                    "No Saved Layouts",
                    systemImage: "rectangle.3.group",
                    description: Text("Arrange your windows and save the layout as a preset.")
                )
            } else {
                List {
                    ForEach(presets) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.body.weight(.medium))

                                HStack(spacing: 8) {
                                    Label(preset.mode.label, systemImage: preset.mode.icon)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text(preset.createdAt, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Spacer()

                            Button("Apply") {
                                NotificationCenter.default.post(name: .quipApplyLayoutPreset, object: preset)
                            }
                            .help("Lay out the main window's enabled windows with this preset")

                            Button("Rename", systemImage: "pencil") {
                                editingPreset = preset
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)

                            Button("Delete", systemImage: "trash", role: .destructive) {
                                deletePreset(preset)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .onAppear { loadPresets() }
        // The main window's Save Layout… writes the same blob while this pane
        // may already be open.
        .onChange(of: savedPresetsData) { _, _ in loadPresets() }
        .sheet(item: $editingPreset) { preset in
            RenamePresetSheet(preset: preset) { newName in
                renamePreset(preset, to: newName)
            }
        }
    }

    private func loadPresets() {
        // Empty blob = no presets saved yet (the @AppStorage default) — silent.
        // Non-empty and undecodable = the user's saved layouts just vanished.
        do {
            presets = try LayoutPresetStore.decode(savedPresetsData)
        } catch {
            QuipLog.write(
                severity: .error, subsystem: "settings",
                message: "savedPresets failed to decode (\(savedPresetsData.count) bytes) "
                       + "— saved layout presets will appear empty: \(error)",
                to: LogPaths.webSocketPath
            )
        }
    }

    private func savePresets() {
        do {
            savedPresetsData = try LayoutPresetStore.encode(presets)
        } catch {
            QuipLog.write(
                severity: .error, subsystem: "settings",
                message: "could not encode \(presets.count) layout presets "
                       + "— the preset was NOT saved and is lost on relaunch: \(error)",
                to: LogPaths.webSocketPath
            )
        }
    }

    private func deletePreset(_ preset: SavedLayoutPreset) {
        presets = LayoutPresetStore.removing(preset.id, from: presets)
        savePresets()
    }

    private func renamePreset(_ preset: SavedLayoutPreset, to name: String) {
        presets = LayoutPresetStore.renaming(preset.id, to: name, in: presets)
        savePresets()
    }
}
