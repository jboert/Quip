// MonitorSelector.swift
// QuipMac — Toolbar display picker for selecting the active monitor

import SwiftUI

struct MonitorSelector: View {
    @Environment(WindowManager.self) private var windowManager
    @Binding var selectedDisplayId: String?

    var body: some View {
        if windowManager.displays.count > 1 {
            Picker("Display", selection: $selectedDisplayId) {
                ForEach(windowManager.displays) { display in
                    Text(displayLabel(for: display))
                        .tag(Optional(display.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else if let display = windowManager.displays.first {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.caption)
                Text(display.name)
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .onAppear {
                selectedDisplayId = display.id
            }
        }
    }

    private func displayLabel(for display: WindowManager.DisplayInfo) -> String {
        let w = Int(display.frame.width)
        let h = Int(display.frame.height)
        return "\(display.name) (\(w)x\(h))"
    }
}
