// GeneralTab.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

// MARK: - General Tab

struct GeneralTab: View {
    @Environment(WhisperStatusStore.self) private var whisperStatus
    @Environment(MacPermissionsStore.self) private var permissionsStore
    @AppStorage("defaultTerminalApp") private var defaultTerminalApp: String = TerminalApp.iterm2.rawValue
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("mirrorDesktop") private var mirrorDesktop = false
    /// Widens the phone's window list to every visible app, not just terminals.
    /// Off by default: it is a real increase in what the phone can type into.
    @AppStorage("mirrorAllApps") private var mirrorAllApps = false
    @AppStorage("crashRecoveryEnabled") private var crashRecoveryEnabled = false
    @State private var crashRecoveryError: String?
    @State private var crashRecoveryReverting = false

    var body: some View {
        // Ordered by why you open General: permissions first (the actionable
        // "something's broken" path), then terminal appearance, then the
        // phone-facing behaviors, then set-once app lifecycle at the bottom.
        // Version moved to the sidebar header; the old control-less "Window
        // Refresh" FYI section was dropped.
        Form {
            Section("Permissions") {
                // Rows track `permissionsStore`, which the app refreshes every
                // 5s off the main thread. Probing here instead ran a blocking
                // Apple Events round-trip inside a SwiftUI body on main, every
                // 3s while this tab was open — see Quip_2026-07-30-091540.hang.
                // Unknown (pre-first-probe) reads as granted, same as the
                // probe's own can't-tell default.
                let perms = permissionsStore.snapshot
                macPermRow(name: "Accessibility", granted: perms?.accessibility ?? true, pane: .accessibility)
                macPermRow(name: "Automation (iTerm)", granted: perms?.appleEvents ?? true, pane: .automation)
                macPermRow(name: "Screen Recording", granted: perms?.screenRecording ?? true, pane: .screenRecording)
                Text("If System Settings already shows Quip enabled but the row stays red, turn Quip off and back on there. Screen Recording changes may require relaunching Quip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Terminal") {
                Picker("Default app", selection: $defaultTerminalApp) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(app.rawValue).tag(app.rawValue)
                    }
                }
            }

            WandSection()

            // Folded in from the former Colors tab — terminal background tints
            // keyed to Claude Code's state. Lives in its own struct so its
            // @AppStorage + @State color bindings stay self-contained.
            TerminalColorsSection()

            // Phone-facing behaviors grouped together: what the phone mirrors,
            // and which recognizer the phone uses for dictation.
            Section("Phone") {
                Toggle("Mirror desktop terminals", isOn: $mirrorDesktop)
                Text("When on, every visible Terminal.app and iTerm2 window shows up on the phone — tap a dimmed one to start driving it. When off, only windows you've explicitly enabled are visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Mirror every app", isOn: $mirrorAllApps)
                Text("Adds non-terminal windows too — Slack, Xcode, a browser — so you can select one on the phone and dictate straight into it. Text and keystrokes go to that app; terminal-only actions (clear, restart, scrollback) are refused for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                whisperStatusRow()
                Text("The phone uses Mac Whisper for dictation when the model is ready, otherwise falls back to on-device SFSpeech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                Toggle("Show in Dock", isOn: $showInDock)
            }

            Section("Reliability") {
                Toggle("Auto-restart on crash", isOn: $crashRecoveryEnabled)
                    .onChange(of: crashRecoveryEnabled) { _, new in
                        applyCrashRecoveryToggle(new)
                    }
                Text("If Quip crashes, macOS launchd relaunches it after 30s. Cmd+Q and normal quits do not trigger relaunch. Installs ~/Library/LaunchAgents/\(CrashRecoveryAgent.label).plist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let err = crashRecoveryError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Wires the Reliability toggle to install/uninstall (see CrashRecoveryToggle).
    /// A failure writes the old value back, which fires `.onChange` again —
    /// `crashRecoveryReverting` swallows that echo so it neither re-runs the
    /// opposite operation nor clears the error it just set.
    private func applyCrashRecoveryToggle(_ requested: Bool) {
        if crashRecoveryReverting {
            crashRecoveryReverting = false
            return
        }
        let result = CrashRecoveryToggle.resolve(requested: requested) { install in
            if install {
                try CrashRecoveryAgent.install()
            } else {
                try CrashRecoveryAgent.uninstall()
            }
        }
        crashRecoveryError = result.error
        if result.enabled != requested {
            crashRecoveryReverting = true
            crashRecoveryEnabled = result.enabled
        }
    }

    @ViewBuilder
    private func whisperStatusRow() -> some View {
        // Mirror the StatusDot look: tinted glyph + label + tail detail. No
        // action buttons — retrying model load is a relaunch-level concern,
        // wiring a manual retry is follow-up work.
        let state = whisperStatus.state
        HStack(spacing: 8) {
            Image(systemName: whisperIcon(for: state))
                .foregroundStyle(whisperColor(for: state))
            Text("Mac Whisper")
            Spacer()
            Text(whisperDetail(for: state))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func whisperIcon(for state: WhisperState) -> String {
        switch state {
        case .ready:            return "checkmark.circle.fill"
        case .preparing:        return "hourglass"
        case .downloading:      return "arrow.down.circle"
        case .failed:           return "xmark.circle.fill"
        }
    }

    private func whisperColor(for state: WhisperState) -> Color {
        switch state {
        case .ready:            return .green
        case .preparing:        return .secondary
        case .downloading:      return .blue
        case .failed:           return .red
        }
    }

    private func whisperDetail(for state: WhisperState) -> String {
        switch state {
        case .ready:
            return "ready — phone will use remote path"
        case .preparing:
            return "loading model…"
        case .downloading(let progress):
            return "downloading \(Int(progress * 100))%"
        case .failed(let message):
            return message
        }
    }

    /// One TCC perm row. Granted = green check. Denied = red ✗ + a "Grant"
    /// button that drops the user straight into the matching System Settings
    /// pane via an x-apple.systempreferences URL — no nav required. Uses the
    /// shared StatusDot (green check / red x) so the Permissions rows speak the
    /// same status vocabulary as every other pane — the last ad-hoc status
    /// glyph folded into StatusDot by the US-003 consistency sweep.
    @ViewBuilder
    private func macPermRow(name: String, granted: Bool, pane: MacSettingsPane) -> some View {
        HStack(spacing: 8) {
            StatusDot(kind: granted ? .ok : .bad, text: name)
            Spacer()
            if !granted {
                Button("Grant") { openSettingsPane(pane) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func openSettingsPane(_ pane: MacSettingsPane) {
        guard let url = pane.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
