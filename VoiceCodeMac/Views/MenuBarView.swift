// MenuBarView.swift
// VoiceCodeMac — Menu bar extra popover for quick access to VoiceCode controls

import SwiftUI

struct MenuBarView: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(BonjourAdvertiser.self) private var bonjourAdvertiser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection

            Divider()

            // Connection status
            connectionSection

            Divider()

            // Quick actions
            actionsSection

            Divider()

            // Footer
            footerSection
        }
        .frame(width: 280)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "rectangle.3.group")
                .font(.title3)
                .foregroundStyle(.tint)

            Text("VoiceCode")
                .font(.headline)

            Spacer()

            statusIndicator
        }
        .padding(12)
    }

    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(webSocketServer.isRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            Text(webSocketServer.isRunning ? "Running" : "Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "wifi")
                    .foregroundStyle(.secondary)
                Text("WebSocket Server")
                    .font(.subheadline.weight(.medium))

                Spacer()

                Toggle(isOn: serverRunningBinding) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if webSocketServer.isRunning {
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if webSocketServer.connectedClientCount > 0 {
                        Text("\(webSocketServer.connectedClientCount) client\(webSocketServer.connectedClientCount == 1 ? "" : "s") connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No clients connected")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Bonjour status
            if bonjourAdvertiser.isAdvertising {
                HStack(spacing: 6) {
                    Image(systemName: "bonjour")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Discoverable on local network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 2) {
            Button {
                arrangeWindows()
            } label: {
                Label("Arrange Windows", systemImage: "rectangle.3.group")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())

            Button {
                windowManager.refreshWindowList()
            } label: {
                Label("Refresh Windows", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())

            Button {
                windowManager.refreshDisplays()
            } label: {
                Label("Refresh Displays", systemImage: "display.2")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text("\(windowManager.windows.filter(\.isEnabled).count) windows managed")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Bindings

    private var serverRunningBinding: Binding<Bool> {
        Binding(
            get: { webSocketServer.isRunning },
            set: { shouldRun in
                if shouldRun {
                    webSocketServer.start()
                    bonjourAdvertiser.startAdvertising()
                } else {
                    webSocketServer.stop()
                    bonjourAdvertiser.stopAdvertising()
                }
            }
        )
    }

    // MARK: - Actions

    private func arrangeWindows() {
        let enabled = windowManager.windows.filter(\.isEnabled)
        let frames = LayoutCalculator.calculate(mode: .columns, windowCount: enabled.count)

        guard let display = windowManager.displays.first(where: { $0.isMain }) ?? windowManager.displays.first else {
            return
        }

        var targetFrames: [String: CGRect] = [:]
        for (index, window) in enabled.enumerated() where index < frames.count {
            targetFrames[window.id] = frames[index].toCGRect(in: display.frame)
        }

        windowManager.arrangeWindows(frames: targetFrames)
    }
}
