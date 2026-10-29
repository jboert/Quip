// ClaudePreviewsRow.swift
// QuipMac — Settings → General → Phone: the Q-87 switch.

import SwiftUI

struct ClaudePreviewsRow: View {
    @Environment(ClaudeHookSwitch.self) private var hookSwitch

    var body: some View {
        Toggle("Show Claude's previews on phone", isOn: Binding(
            get: { hookSwitch.isOn },
            set: { hookSwitch.set($0, source: "mac-settings") }
        ))
        .disabled(ClaudeHookSwitch.bundledHookPath == nil)
        statusLine
            .font(.caption)
            .foregroundStyle(.secondary)
            .onAppear { hookSwitch.refresh() }
    }

    @ViewBuilder private var statusLine: some View {
        if let error = hookSwitch.lastError {
            Text(error).foregroundStyle(.red)
        } else {
            switch hookSwitch.status {
            case .stale:
                HStack {
                    Text("Claude is set up to use an older copy of Quip.")
                    Button("Repair") { hookSwitch.set(true, source: "mac-settings-repair") }
                        .buttonStyle(.link)
                }
            case .unreadable:
                Text("Claude's settings file (~/.claude/settings.json) isn't valid JSON, so Quip won't change it.")
                    .foregroundStyle(.red)
            case .on, .off:
                Text("When Claude opens an image or PDF on this Mac (for example a simulator screenshot), the phone shows it on that terminal. Only files Claude opens are sent — never Preview windows you open yourself. Quip sets this up by itself: it adds one hook to Claude Code's settings, and turning this off removes it.")
            }
        }
    }
}
