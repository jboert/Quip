// MenuBarView.swift
// QuipMac — Menu bar extra popover for quick access to Quip controls

import SwiftUI

struct MenuBarView: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(BonjourAdvertiser.self) private var bonjourAdvertiser
    @Environment(CloudflareTunnel.self) private var tunnel
    @Environment(ConnectionLog.self) private var connectionLog

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

            Text("Quip")
                .font(.headline)

            Spacer()

            statusIndicator
        }
        .padding(12)
    }

    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Aggregate health: green = server running, ≥1 client, tunnel ready (or
    /// tunnel disabled). Yellow = server running but listener-only (no
    /// clients OR tunnel still resolving). Red = server stopped. Three-color
    /// signal lets the user read overall state from the menubar dot before
    /// even opening the popover.
    private var statusColor: Color {
        guard webSocketServer.isRunning else { return .red }
        let tunnelHealthy = !tunnel.isRunning || !tunnel.publicURL.isEmpty
        if webSocketServer.connectedClientCount > 0 && tunnelHealthy {
            return .green
        }
        return .yellow
    }

    private var statusLabel: String {
        guard webSocketServer.isRunning else { return "Stopped" }
        if webSocketServer.connectedClientCount > 0 { return "Active" }
        return "Listening"
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
                if webSocketServer.connectedClients.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "iphone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("No clients connected")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    // §B5 per-client list. Each row: device name + relative
                    // last-activity. Auth state encoded as filled/empty icon
                    // so the user can spot a "connected but never authed"
                    // half-state (often the symptom of a wrong PIN).
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(webSocketServer.connectedClients) { c in
                            HStack(spacing: 6) {
                                Image(systemName: clientIcon(c))
                                    .font(.caption)
                                    .foregroundStyle(c.isAuthenticated ? .green : .yellow)
                                Text(c.displayTitle)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(Self.relativeTimeFormatter.localizedString(for: c.lastActivity, relativeTo: Date()))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
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

            // Cloudflare tunnel status — visible only when the tunnel is
            // active. Truncates the long *.trycloudflare.com host to a
            // readable prefix; the user copies the full URL from Settings
            // if needed. Yellow dot when tunnel is up but URL not yet
            // resolved (the new stall watchdog from §45 will restart it).
            if tunnel.isRunning {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tunnel.publicURL.isEmpty ? Color.yellow : Color.green)
                        .frame(width: 6, height: 6)
                    Text(tunnelLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // Last connection event — pulled from the same ConnectionLog
            // ring buffer the Settings → Diagnostics tab uses. Single-line
            // glance at "what just happened with the phone" without having
            // to open Settings.
            if let last = connectionLog.events.first {
                HStack(spacing: 6) {
                    Image(systemName: lastEventIcon(last.kind))
                        .font(.caption2)
                        .foregroundStyle(lastEventColor(last.kind))
                    Text("\(last.kind.rawValue) · \(Self.relativeTimeFormatter.localizedString(for: last.timestamp, relativeTo: Date()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
    }

    private var tunnelLabel: String {
        if tunnel.publicURL.isEmpty {
            return "Tunnel: resolving…"
        }
        let trimmed = tunnel.publicURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: ".trycloudflare.com", with: "")
        return "Tunnel: \(trimmed)"
    }

    private func clientIcon(_ c: WebSocketServer.ConnectedClientInfo) -> String {
        switch c.deviceKind {
        case "ios": return "iphone"
        case "watchos": return "applewatch"
        case "linux": return "desktopcomputer"
        case "mac": return "laptopcomputer"
        default: return c.isAuthenticated ? "iphone" : "iphone.slash"
        }
    }

    private func lastEventIcon(_ kind: ConnectionEvent.Kind) -> String {
        switch kind {
        case .connected, .authSucceeded: return "checkmark.circle.fill"
        case .disconnected: return "circle.dotted"
        case .authFailed: return "lock.slash.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func lastEventColor(_ kind: ConnectionEvent.Kind) -> Color {
        switch kind {
        case .connected, .authSucceeded: return .green
        case .disconnected: return .secondary
        case .authFailed, .failed: return .red
        }
    }

    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

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

            if let version = Self.appVersionString {
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

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

    /// CFBundleShortVersionString from Info.plist (e.g. "1.0-eb-branch").
    private static var appVersionString: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
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
