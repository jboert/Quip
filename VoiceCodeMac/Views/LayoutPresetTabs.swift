// LayoutPresetTabs.swift
// VoiceCodeMac — Layout mode selector with segmented control and custom template picker

import SwiftUI

struct LayoutPresetTabs: View {
    @Binding var selectedMode: LayoutMode
    @Binding var selectedTemplate: CustomLayoutTemplate
    @Binding var isDragToResizeEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Primary mode selector
            Picker("Layout", selection: $selectedMode) {
                ForEach(LayoutMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Custom mode sub-options
            if selectedMode == .custom {
                HStack(spacing: 12) {
                    Picker("Template", selection: $selectedTemplate) {
                        ForEach(CustomLayoutTemplate.allCases) { template in
                            Text(template.rawValue).tag(template)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)

                    Divider()
                        .frame(height: 18)

                    Toggle(isOn: $isDragToResizeEnabled) {
                        Label("Drag to Resize", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(.horizontal, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(duration: 0.3), value: selectedMode)
    }
}
