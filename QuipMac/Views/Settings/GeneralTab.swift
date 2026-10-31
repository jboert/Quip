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
    // Q-90 Reliability, all on by default (ReliabilityPrefs).
    @AppStorage(ReliabilityPrefs.keepRunningKey) private var keepRunning = true
    @AppStorage(ReliabilityPrefs.afterQuitKey) private var restartAfterQuit = true
    @AppStorage(ReliabilityPrefs.frozenKey) private var restartFrozen = true
    @State private var reliabilityStatus: ReliabilityStatusMessage?
    @State private var reliabilityError: String?
    @State private var restarts: [ReliabilityRestarts.Entry] = []
    @State private var restartFrames: [Date: [String]] = [:]

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
                Text("When on, every visible Terminal.app and iTerm2 window shows up on the phone — tap a dimmed one to start driving it. When off, only windows you've explicitly enabled are visible; they stay enabled across a Quip relaunch or reinstall until the Mac reboots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Mirror every app", isOn: $mirrorAllApps)
                Text("Adds non-terminal windows too — Slack, Xcode, a browser — so you can select one on the phone and dictate straight into it. Text and keystrokes go to that app; terminal-only actions (clear, restart, scrollback) are refused for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ClaudePreviewsRow()

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
                Toggle("Keep Quip running", isOn: $keepRunning)
                    .onChange(of: keepRunning) { _, _ in applyReliability() }
                Text(reliabilityLine)
                    .font(.caption)
                    .foregroundStyle(reliabilityStatus?.watching == false && keepRunning ? .orange : .secondary)
                DisclosureGroup("Advanced") {
                    Toggle("Restart after Quit", isOn: $restartAfterQuit)
                        .onChange(of: restartAfterQuit) { _, _ in applyReliability() }
                    Toggle("Restart a frozen Quip", isOn: $restartFrozen)
                        .onChange(of: restartFrozen) { _, _ in applyReliability() }
                }
                .disabled(!keepRunning)
                Text("Quip comes back by itself after a crash, a quit or a freeze, so your phone can reach this Mac. Stop Quip… in the menu bar stops it on purpose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !restarts.isEmpty {
                    ForEach(Array(restarts.enumerated()), id: \.offset) { _, entry in
                        restartRow(entry)
                    }
                }
                if let err = reliabilityError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .task { refreshReliabilityStatus() }
        }
        .formStyle(.grouped)
    }

    /// Plain words under the switch (spec §5).
    private var reliabilityLine: String {
        guard keepRunning else { return "Off: if Quip stops, your phone can't reach this Mac until you open it." }
        guard let status = reliabilityStatus else { return "Checking…" }
        guard status.watching else { return "Not watching this Quip yet. Quit and open Quip to fix it." }
        if let last = status.lastRestart {
            return "Watching Quip · restarted after \(last.reason.replacingOccurrences(of: "_", with: " ")) at \(Date(timeIntervalSince1970: last.at).formatted(date: .omitted, time: .shortened))"
        }
        return "Watching Quip"
    }

    /// Q-90: applies the switches to the launch agents. A copy that launchd
    /// did not start hands over to the agent's copy (and quits) when the
    /// agent is now on, so the Quip that runs is the one launchd restarts.
    private func applyReliability() {
        guard ReliabilityAgents.isInstallLocation else {
            reliabilityError = "Move Quip to /Applications to use this."
            return
        }
        reliabilityError = nil
        let replaced = ReliabilityAgents.sync()
        NotificationCenter.default.post(name: .quipReliabilityChanged, object: nil)
        if !replaced, ReliabilityLaunch.handOffIfNeeded() {
            NSApp.terminate(nil)
            return
        }
        refreshReliabilityStatus()
    }

    /// One past restart: when, why, and Copy for a ticket (spec US-007).
    private func restartRow(_ entry: ReliabilityRestarts.Entry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                    .monospacedDigit()
                Text("· \(ReliabilityRestarts.words(entry.reason))")
                if entry.repeated {
                    Text("· same cause 3×")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Copy for a ticket") {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: LogPaths.directory.path)) ?? []
                    let text = ReliabilityRestarts.ticketText(
                        entry, build: BuildInfo.shortDisplay(BuildInfo.current),
                        sample: ReliabilityRestarts.sampleName(for: entry, in: names),
                        frames: restartFrames[entry.at] ?? [])
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.link)
            }
            ForEach(restartFrames[entry.at] ?? [], id: \.self) { frame in
                Text(frame)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
    }

    private func refreshReliabilityStatus() {
        restarts = ReliabilityRestarts.recent(restartsJSON: try? Data(contentsOf: ReliabilityFiles.restarts))
        let launchedAt = QuipHeartbeat.shared.startedAt
        let entries = restarts
        DispatchQueue.global(qos: .utility).async {
            let status = ReliabilityReport.current(launchedAt: launchedAt)
            let frames = ReliabilityFrames.load(for: entries)
            DispatchQueue.main.async { reliabilityStatus = status; restartFrames = frames }
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
        // Automation has no "+" in System Settings: an entry only appears once
        // macOS has asked. Ask first (off main, it blocks on tccd and the
        // dialog); open the pane only when macOS already holds a denial.
        if pane == .automation {
            DispatchQueue.global(qos: .userInitiated).async {
                guard !PermissionProbeService.requestAppleEventsAccess() else { return }
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            return
        }
        NSWorkspace.shared.open(url)
    }
}
