// SecurityTab.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

// MARK: - Security Tab

struct SecurityTab: View {
    @Environment(PINManager.self) private var pinManager
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(CloudflareTunnel.self) private var tunnel
    @Environment(TailscaleService.self) private var tailscale

    // The pairing URL must match wherever the phone actually connects, so
    // we branch on the same mode the user picked in the Connection tab.
    @AppStorage("networkMode") private var networkModeRaw: String = NetworkMode.cloudflareTunnel.rawValue

    private var networkMode: NetworkMode {
        NetworkMode(rawValue: networkModeRaw) ?? .cloudflareTunnel
    }

    // Diagnostics-bundle state — folded in from the former Diagnostics
    // tab. Co-located with PIN + pairing here because both topics are
    // about "what does this Mac expose to phones, and what shows up in
    // logs about that exposure?" Single tab keeps the auth-and-audit
    // story in one place.
    @State private var lastBundlePath: String?
    @State private var lastError: String?
    @State private var bundling: Bool = false
    @State private var anchorView: NSView?
    // Separate anchor for the "Send to iPhone" pairing-link share picker so it
    // pins to its own button, not the diagnostics "Bundle and share…" one.
    @State private var pairingAnchorView: NSView?
    /// Rendered off the main actor whenever the pairing link changes.
    @State private var qrImage: NSImage?

    var body: some View {
        Form {
            Section {
                LabeledContent("PIN") {
                    HStack(spacing: 8) {
                        TextField("PIN", text: Bindable(pinManager).pin)
                            .font(.system(size: 24, weight: .medium, design: .monospaced))
                            .frame(minWidth: 180)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: pinManager.pin) {
                                pinManager.savePIN()
                            }

                        CopyButton(value: pinManager.pin, help: "Copy PIN")
                    }
                }

                Button {
                    pinManager.regeneratePIN()
                } label: {
                    Label("Generate New PIN", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("PIN")
            } footer: {
                Text("The iPhone enters this PIN when pairing. Generating a new PIN replaces the old one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                pairingQRBlock

                AnchoredButton(anchor: $pairingAnchorView) {
                    sharePairingLink()
                } label: {
                    Label("Send to iPhone…", systemImage: "square.and.arrow.up")
                }
                .disabled(pairingURL().isEmpty)
            } header: {
                Text("Pair iPhone")
            } footer: {
                Text("The iPhone Camera app can’t open this QR (it shows “No usable data found”). Scan it inside the Quip app — qrcode.viewfinder button in the URL bar — to auto-fill the URL and PIN, no typing. Or tap “Send to iPhone” to AirDrop / Message / Mail a quip://pair link the phone taps to pair, no scan needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Logs directory") {
                    Text(LogPaths.directory.path)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([LogPaths.directory])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            } header: {
                Text("Diagnostics — log location")
            } footer: {
                Text("Logs survive reboot and are indexed by Console.app under the \"Quip\" filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                AnchoredButton(anchor: $anchorView) {
                    bundleAndShare()
                } label: {
                    HStack {
                        if bundling {
                            ProgressView().controlSize(.small)
                        }
                        Label("Bundle and share…", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(bundling)

                if let path = lastBundlePath {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            StatusDot(kind: .ok, text: "Bundle ready")
                            Spacer()
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        Text(path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }

                if let err = lastError {
                    StatusDot(kind: .bad, text: err)
                }
            } header: {
                Text("Diagnostics — share")
            } footer: {
                Text("Bundles the three log files plus a system-info text blob into a single zip in /tmp, then opens AirDrop / Mail / Messages. The phone-side equivalent (Settings → Diagnostics → Get Mac logs) sends the same bundle over WebSocket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func bundleAndShare() {
        bundling = true
        lastError = nil
        Task {
            do {
                let zipURL = try await Task.detached { try DiagnosticsBundle.makeZip() }.value
                lastBundlePath = zipURL.path
                bundling = false
                DiagnosticsBundle.presentSharePicker(zipURL: zipURL, anchor: anchorView)
            } catch {
                lastError = error.localizedDescription
                bundling = false
            }
        }
    }

    /// Share the pairing link so a remote phone can tap-to-pair without the
    /// QR or the native Camera. Mirrors the diagnostics-share pattern
    /// (NSSharingServicePicker pinned to an AnchoredButton): a tappable
    /// quip://pair?url=…&pin=… link plus a plaintext "<ws url>\nPIN: <pin>"
    /// fallback for share targets that ignore custom-scheme URLs.
    @MainActor
    private func sharePairingLink() {
        let url = pairingURL()
        guard !url.isEmpty else { return }
        let payload = PairingPayload(url: url, pin: pinManager.pin)
        var items: [Any] = []
        if let encoded = payload.encodedURL(), let link = URL(string: encoded) {
            items.append(link)
        }
        items.append("\(url)\nPIN: \(pinManager.pin)")
        let picker = NSSharingServicePicker(items: items)
        if let anchor = pairingAnchorView {
            picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
        } else if let window = NSApp.keyWindow,
                  let contentView = window.contentView {
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }

    /// Renders a pairing QR for whichever URL is currently most useful: the
    /// Cloudflare tunnel URL (cross-network) when up, otherwise the local
    /// Bonjour/IP URL the iPhone can reach over LAN. Re-renders whenever
    /// the tunnel resolves a new URL or the PIN regenerates — no manual
    /// refresh button needed because the views are bound to @Observable
    /// state.
    @ViewBuilder
    private var pairingQRBlock: some View {
        let currentURL = pairingURL()
        if currentURL.isEmpty {
            Text("Start the WebSocket server to display a pairing QR.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let encoded = PairingPayload(url: currentURL, pin: pinManager.pin).encodedURL()
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan in the Quip app — the Camera app can’t open it")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 16) {
                    if let qr = qrImage {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 160, height: 160)
                            .background(Color.white)
                            .clipShape(.rect(cornerRadius: 6))
                    } else {
                        Color.secondary.frame(width: 160, height: 160).clipShape(.rect(cornerRadius: 6))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("URL")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(currentURL)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Text("PIN")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Text(pinManager.pin)
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .task(id: encoded) {
                guard let encoded else { qrImage = nil; return }
                qrImage = await PairingQR.render(for: encoded)
            }
        }
    }

    /// Embed the URL the iPhone will actually reach, branching on the active
    /// network mode so a Tailscale-mode link carries the stable ts.net / 100.x
    /// address instead of a useless ws://<host>.local. Mirrors the per-mode URL
    /// sources surfaced in ConnectionTab's "Diagnostics — Connection URLs" rows:
    ///   .tailscale        → TailscaleService.webSocketURL (ts.net / 100.x)
    ///   .cloudflareTunnel → tunnel.webSocketURL (works on cellular too)
    ///   .localOnly        → LAN ws://<host>.local:<listenPort>
    /// Empty when the chosen mode has no URL yet (server stopped, or
    /// tunnel/Tailscale not resolved) — the QR block shows a "start the server"
    /// hint in that case.
    private func pairingURL() -> String {
        switch networkMode {
        case .tailscale:
            return tailscale.webSocketURL
        case .cloudflareTunnel:
            return tunnel.webSocketURL
        case .localOnly:
            guard webSocketServer.isRunning else { return "" }
            let host = Host.current().localizedName ?? "localhost"
            return "ws://\(host).local:\(WebSocketServer.listenPort)"
        }
    }
}
