// MonitorSelector.swift
// VoiceCodeMac — Toolbar display picker for selecting the active monitor

import SwiftUI

struct MonitorSelector: View {
    @Environment(WindowManager.self) private var windowManager
    @Binding var selectedDisplayId: String?

    var body: some View {
        Picker("Display", selection: $selectedDisplayId) {
            ForEach(windowManager.displays) { display in
                HStack(spacing: 6) {
                    Image(systemName: display.isMain ? "display" : "rectangle.on.rectangle")
                        .font(.caption)
                    Text(display.name)
                    Text(resolutionLabel(for: display))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(Optional(display.id))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onAppear {
            if selectedDisplayId == nil {
                selectedDisplayId = windowManager.displays.first(where: { $0.isMain })?.id
                    ?? windowManager.displays.first?.id
            }
        }
        .onChange(of: windowManager.displays) {
            if let current = selectedDisplayId,
               !windowManager.displays.contains(where: { $0.id == current }) {
                selectedDisplayId = windowManager.displays.first?.id
            }
        }
    }

    private func resolutionLabel(for display: WindowManager.DisplayInfo) -> String {
        let w = Int(display.frame.width)
        let h = Int(display.frame.height)
        return "\(w) x \(h)"
    }
}
