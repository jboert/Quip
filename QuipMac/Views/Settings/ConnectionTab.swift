// ConnectionTab.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

// MARK: - Connection Tab

struct ConnectionTab: View {
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(BonjourAdvertiser.self) private var bonjourAdvertiser
    @Environment(TailscaleService.self) private var tailscale
    @Environment(CloudflareTunnel.self) private var tunnel
    @Environment(ConnectionLog.self) private var connectionLog

    @AppStorage("bonjourServiceName") private var serviceName: String = "Quip"
    @AppStorage("networkMode") private var networkModeRaw: String = NetworkMode.cloudflareTunnel.rawValue
    @AppStorage("tailscaleHostnameOverride") private var tailscaleOverride: String = ""
    // Default TRUE (secure): mirrors WebSocketServer.resolveRequirePIN — an unset
    // key requires PIN; only this toggle's explicit opt-out stores false.
    @AppStorage("requirePINForLocal") private var requirePINForLocal = true
    @AppStorage("spawnCommand") private var spawnCommand: String = "claude"
    /// Filled in .task and on server start/stop — walking the interfaces from
    /// `body` ran getifaddrs on every client tick.
    @State private var lanURL: String = ""

    private var networkMode: NetworkMode {
        NetworkMode(rawValue: networkModeRaw) ?? .cloudflareTunnel
    }

    private var modeCaption: String {
        switch networkMode {
        case .cloudflareTunnel:
            return "Cloudflare tunnel enables connections from anywhere. Local connections always require PIN when tunnel is active."
        case .tailscale:
            return "Both devices must be on your Tailscale network. The URL stays stable across restarts."
        case .localOnly:
            return "Clients must be on the same network. QR code shows local address."
        }
    }

    /// Focal point of the Connection pane — the one thing it answers: can my
    /// phone reach this Mac? A status glyph + headline + a live subline (mode +
    /// connected count). Replaces the buried "Status: ● Running" label row.
    @ViewBuilder
    private var connectionHero: some View {
        let running = webSocketServer.isRunning
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill((running ? Color.green : Color.red).opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: running
                      ? "antenna.radiowaves.left.and.right"
                      : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(running ? .green : .red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(running ? "Server running" : "Server stopped")
                    .font(.title3.weight(.semibold))
                Text(statusSubline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var statusSubline: AttributedString {
        guard webSocketServer.isRunning else {
            return AttributedString("Start to accept connections from your iPhone")
        }
        let n = webSocketServer.connectedClientCount
        let mode = networkMode.displayName
        if n == 0 { return AttributedString("Listening · \(mode) · no phones connected yet") }
        return AttributedString(localized: "^[\(n) phone](inflect: true) connected · \(mode)")
    }

    var body: some View {
        Form {
            Section {
                connectionHero
            }

            Section("Server") {
                LabeledContent("Port") {
                    Text(verbatim: String(WebSocketServer.listenPort))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                TextField("Bonjour service name", text: $serviceName)
                LabeledContent("Bonjour discovery") {
                    StatusDot(kind: bonjourAdvertiser.isAdvertising ? .ok : .bad,
                              text: bonjourAdvertiser.isAdvertising ? "Advertising" : "Stopped")
                }
            }

            // §B5 per-client visibility — full table of every active socket so
            // "is anyone actually talking to me?" answers from a glance instead
            // of a `netstat | grep 8765` ritual.
            Section("Connected Clients") {
                let clients: [WebSocketServer.ConnectedClientInfo] = webSocketServer.connectedClients
                if clients.isEmpty {
                    Text("None — server is listening but no client has connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(clients) { (c: WebSocketServer.ConnectedClientInfo) in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: clientIcon(c))
                                    .foregroundStyle(c.isAuthenticated ? .green : .yellow)
                                Text(c.displayTitle).font(.body.weight(.medium))
                                Spacer()
                                Text(c.isAuthenticated ? "authed" : "awaiting auth")
                                    .font(.caption)
                                    .foregroundStyle(c.isAuthenticated ? Color.secondary : Color.orange)
                            }
                            HStack(spacing: 12) {
                                Text(c.remote)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                if let kind = c.deviceKind {
                                    Text(kind)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text("connected \(Self.relTime.localizedString(for: c.connectedAt, relativeTo: Date.now))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text("· last \(Self.relTime.localizedString(for: c.lastActivity, relativeTo: Date.now))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Network Mode") {
                Picker("Network Mode", selection: $networkModeRaw) {
                    ForEach(NetworkMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(modeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if networkMode == .tailscale {
                    LabeledContent("Hostname") {
                        if tailscale.hostname.isEmpty {
                            Text("Not detected")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text(tailscale.hostname)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    Button {
                        tailscale.refresh()
                    } label: {
                        Label("Re-detect", systemImage: "arrow.clockwise")
                    }

                    TextField("Hostname override (optional)", text: $tailscaleOverride)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tailscaleOverride) { _, _ in
                            tailscale.refresh()
                        }

                    if let err = tailscale.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Toggle("Require PIN for local connections", isOn: $requirePINForLocal)
                    .onChange(of: requirePINForLocal) { _, newValue in
                        webSocketServer.requireAuth = newValue
                    }
            }

            Section("New Window Spawning") {
                TextField("Claude command", text: $spawnCommand)
                    .textFieldStyle(.roundedBorder)
                Text("Used when the phone selects Claude. Codex runs `codex`; Terminal opens a bare shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics — Connection URLs") {
                // Show every URL the phone could reasonably try right now —
                // LAN, Tailscale, Cloudflare tunnel — each with a one-click
                // copy. Debugging "nothing's loading on the phone" used to
                // mean guessing which URL it had saved; now it's literally
                // "copy this into the app's URL field."
                urlRow(label: "LAN", url: lanURL)
                if let tsURL = tailscaleWSURL {
                    urlRow(label: "Tailscale", url: tsURL)
                }
                if !tunnel.webSocketURL.isEmpty {
                    urlRow(label: "Cloudflare", url: tunnel.webSocketURL)
                }
            }

            Section("Diagnostics — Recent Connections") {
                if connectionLog.events.isEmpty {
                    Text("No connection attempts recorded yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(connectionLog.events) { event in
                                connectionLogRow(event)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)

                    Button {
                        connectionLog.clear()
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .task { lanURL = Self.lanWSURL() }
        .onChange(of: webSocketServer.isRunning) { lanURL = Self.lanWSURL() }
    }

    @ViewBuilder
    private func urlRow(label: String, url: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(url)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                CopyButton(value: url, help: "Copy \(url)")
            }
        }
    }

    @ViewBuilder
    private func connectionLogRow(_ event: ConnectionEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Locale-aware, so a 12-hour locale adds "AM"/"PM" — hence 80 not 70.
            Text(event.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .leading)

            Text(Self.eventLabel(event.kind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Self.eventColor(event.kind))
                .frame(width: 90, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.remote)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private var tailscaleWSURL: String? {
        let url = tailscale.webSocketURL
        return url.isEmpty ? nil : url
    }

    /// The LAN URL helper in `MainWindow.swift` uses the same getifaddrs loop —
    /// we duplicate it here rather than reach across views for a private field.
    /// Runs when the pane opens and when the server starts or stops, never
    /// from `body` (which re-runs on every client tick).
    private static func lanWSURL() -> String {
        var address = "localhost"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while let ifa = ptr {
                let sa = ifa.pointee.ifa_addr.pointee
                if sa.sa_family == UInt8(AF_INET) {
                    let name = String(cString: ifa.pointee.ifa_name)
                    if name.hasPrefix("en") {
                        let addr = ifa.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        let ip = String(cString: inet_ntoa(addr.sin_addr))
                        if ip != "127.0.0.1" {
                            address = ip
                            break
                        }
                    }
                }
                ptr = ifa.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return "ws://\(address):\(WebSocketServer.listenPort)"
    }

    private static func eventLabel(_ kind: ConnectionEvent.Kind) -> String {
        switch kind {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .authSucceeded: return "Auth ✓"
        case .authFailed: return "Auth ✗"
        case .failed: return "Failed"
        }
    }

    private static func eventColor(_ kind: ConnectionEvent.Kind) -> Color {
        switch kind {
        case .connected, .authSucceeded: return .green
        case .disconnected: return .secondary
        case .authFailed, .failed: return .red
        }
    }

    private static let relTime: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func clientIcon(_ c: WebSocketServer.ConnectedClientInfo) -> String {
        switch c.deviceKind {
        case "ios": return "iphone"
        case "watchos": return "applewatch"
        case "linux": return "desktopcomputer"
        case "mac": return "laptopcomputer"
        default: return "iphone"
        }
    }
}
