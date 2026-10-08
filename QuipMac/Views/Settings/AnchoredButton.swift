// AnchoredButton.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

/// SwiftUI Button wrapper that captures the underlying NSView via
/// NSViewRepresentable, so callers can pin an NSSharingServicePicker
/// to the button's frame instead of the whole window.
struct AnchoredButton<Label: View>: View {
    @Binding var anchor: NSView?
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .background(AnchorCapture(anchor: $anchor))
    }

    private struct AnchorCapture: NSViewRepresentable {
        @Binding var anchor: NSView?
        func makeNSView(context: Context) -> NSView {
            let v = NSView(frame: .zero)
            Task { @MainActor in anchor = v }
            return v
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}
