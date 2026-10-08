// TerminalColorsSection.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

/// Terminal background tints keyed to Claude Code's state. A self-contained
/// `Section` (folded in from the former Colors tab) so it drops straight into
/// the General Form. Keeps its own @AppStorage hex + @State Color bindings.
struct TerminalColorsSection: View {
    @AppStorage("colorNeutral") private var neutralHex: String = "#1E1E1E"
    @AppStorage("colorWaiting") private var waitingHex: String = "#001430"
    @AppStorage("colorSTTActive") private var sttActiveHex: String = "#240040"

    @State private var neutralColor: Color = Color(hex: "#1E1E1E")
    @State private var waitingColor: Color = Color(hex: "#001430")
    @State private var sttActiveColor: Color = Color(hex: "#240040")

    var body: some View {
        Section {
            ColorPicker(selection: $neutralColor, supportsOpacity: false) {
                colorLabel("Neutral", "Claude is actively processing")
            }
            ColorPicker(selection: $waitingColor, supportsOpacity: false) {
                colorLabel("Waiting for Input", "Claude is idle, ready for a prompt")
            }
            ColorPicker(selection: $sttActiveColor, supportsOpacity: false) {
                colorLabel("Speech-to-Text Active", "Dictation is in progress")
            }
            Button("Reset to Defaults") {
                neutralColor = Color(hex: "#1E1E1E")
                waitingColor = Color(hex: "#001430")
                sttActiveColor = Color(hex: "#240040")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } header: {
            Text("Terminal Colors")
        } footer: {
            Text("Applied to terminal windows based on Claude Code's current state.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func colorLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body.weight(.medium))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
