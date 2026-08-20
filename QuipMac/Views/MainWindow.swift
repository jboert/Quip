// MainWindow.swift
// QuipMac — Top-level window view with sidebar, layout preview, and toolbars

import SwiftUI
import Darwin

struct MainWindow: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(BonjourAdvertiser.self) private var bonjourAdvertiser
    @Environment(CloudflareTunnel.self) private var tunnel
    @Environment(TailscaleService.self) private var tailscale

    @AppStorage("networkMode") private var networkModeRaw: String = NetworkMode.cloudflareTunnel.rawValue

    private var networkMode: NetworkMode {
        NetworkMode(rawValue: networkModeRaw) ?? .cloudflareTunnel
    }

    private static func computeLocalWSURL() -> String {
        let port = 8765
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
        return "ws://\(address):\(port)"
    }

    @State private var selectedDisplayId: String?
    @State private var selectedWindowId: String?
    @State private var localWSURL: String = MainWindow.computeLocalWSURL()

    @State private var layoutMode: LayoutMode = .columns
    @State private var customTemplate: CustomLayoutTemplate = .largeLeftSmallRight
    @State private var isDragToResizeEnabled = false
    @State private var customFrames: [String: NormalizedRect] = [:]
    @State private var showQRPopover = false
    /// Non-nil while an Arrange attempt has something to say — missing
    /// permission, no enabled windows, no display.
    @State private var arrangeError: String?

    var body: some View {
        NavigationSplitView {
            WindowListSidebar(
                selectedWindowId: $selectedWindowId
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 340)
        } detail: {
            detailContent
        }
        .toolbar {
            toolbarContent
        }
        .alert("Couldn't arrange windows", isPresented: Binding(
            get: { arrangeError != nil },
            set: { if !$0 { arrangeError = nil } }
        )) {
            Button("Open Accessibility Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
                arrangeError = nil
            }
            Button("OK", role: .cancel) { arrangeError = nil }
        } message: {
            Text(arrangeError ?? "")
        }
        .onAppear {
            windowManager.refreshDisplays()
            windowManager.refreshWindowList()
            localWSURL = Self.computeLocalWSURL()
            if selectedDisplayId == nil {
                selectedDisplayId = windowManager.displays.first(where: { $0.isMain })?.id
                    ?? windowManager.displays.first?.id
            }
        }
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        let snapshot = layoutSnapshot

        VStack(spacing: 0) {
            // Layout + monitor row
            HStack(spacing: 12) {
                LayoutPresetTabs(
                    selectedMode: $layoutMode,
                    selectedTemplate: $customTemplate,
                    isDragToResizeEnabled: $isDragToResizeEnabled
                )
                // Picking a preset means "lay them out like this" — keeping the
                // hand-dragged rects would make the preset look broken.
                .onChange(of: layoutMode) { _, _ in customFrames.removeAll() }
                .onChange(of: customTemplate) { _, _ in customFrames.removeAll() }

                if !customFrames.isEmpty {
                    Button("Reset sizes") { customFrames.removeAll() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Discard hand-dragged window sizes and go back to the preset")
                }

                Spacer()

                MonitorSelector(
                    selectedDisplayId: $selectedDisplayId
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Layout preview
            LayoutPreview(
                windows: snapshot.displayWindows,
                frames: snapshot.currentFrames,
                layoutMode: layoutMode,
                isDragToResizeEnabled: isDragToResizeEnabled,
                customFrames: $customFrames,
                onReorder: { fromIndex, toIndex in
                    reorderWindows(from: fromIndex, to: toIndex)
                }
            )
            .animation(.spring(duration: 0.4), value: layoutMode)
            .animation(.spring(duration: 0.4), value: snapshot.enabledWindowCount)

            Divider()

            // Bottom bar
            HStack(spacing: 10) {
                connectionStatus

                Spacer()

                tunnelStatus

                Button {
                    showQRPopover.toggle()
                } label: {
                    Image(systemName: "qrcode")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show QR code for iPhone")
                .help("Show QR code for iPhone")
                .popover(isPresented: $showQRPopover) {
                    tunnelQRPopover
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                arrangeWindows()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.3.group")
                    Text("Arrange")
                }
                .font(.body.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(enabledWindowCount == 0)
            .help("Arrange enabled windows using the selected layout")
        }
    }

    // MARK: - QR Popover

    private var tunnelQRPopover: some View {
        let qrURL: String = {
            switch networkMode {
            case .cloudflareTunnel: return tunnel.webSocketURL
            case .tailscale:        return tailscale.webSocketURL
            case .localOnly:        return localWSURL
            }
        }()

        return VStack(spacing: 12) {
            if networkMode == .cloudflareTunnel && qrURL.isEmpty {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for tunnel...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if networkMode == .tailscale && qrURL.isEmpty {
                if let err = tailscale.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Detecting Tailscale...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Scan with iPhone")
                    .font(.headline)

                if let qrImage = generateQR(from: qrURL) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                }

                HStack(spacing: 8) {
                    Text(qrURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(qrURL, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy connection URL")
                }
            }
        }
        .padding(20)
        .frame(width: 280)
    }

    private func generateQR(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: - Tunnel Status

    private var tunnelStatus: some View {
        HStack(spacing: 6) {
            switch networkMode {
            case .localOnly:
                Image(systemName: "house")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("Local only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(localWSURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(localWSURL, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy local URL")
                .help("Copy local URL")

            case .tailscale:
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(tailscale.isAvailable ? .blue : .red)
                if tailscale.isAvailable && !tailscale.webSocketURL.isEmpty {
                    Text(tailscale.webSocketURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tailscale.webSocketURL, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy Tailscale URL")
                    .help("Copy Tailscale URL")
                } else if let err = tailscale.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Detecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .cloudflareTunnel:
                if tunnel.isRunning && !tunnel.webSocketURL.isEmpty {
                    Image(systemName: "globe")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(tunnel.webSocketURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tunnel.webSocketURL, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy tunnel URL")
                    .help("Copy tunnel URL")
                } else if tunnel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting tunnel...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "globe")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text("Tunnel offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Connection Status

    private var connectionStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(webSocketServer.isRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            if webSocketServer.connectedClientCount > 0 {
                Text("\(webSocketServer.connectedClientCount) client\(webSocketServer.connectedClientCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if webSocketServer.isRunning {
                Text("Listening")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Offline")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Computed Properties

    private struct LayoutSnapshot {
        let displayWindows: [ManagedWindow]
        let enabledWindowCount: Int
        let currentFrames: [NormalizedRect]
    }

    private var layoutSnapshot: LayoutSnapshot {
        let displayWindows = displayWindows
        // One source for the frames — the preview and Arrange must not compute
        // them differently, or a resized tile would move on arrange.
        return LayoutSnapshot(
            displayWindows: displayWindows,
            enabledWindowCount: displayWindows.lazy.filter(\.isEnabled).count,
            currentFrames: currentFrames
        )
    }

    private var selectedDisplay: WindowManager.DisplayInfo? {
        if let id = selectedDisplayId {
            return windowManager.displays.first { $0.id == id }
        }
        return windowManager.displays.first(where: { $0.isMain }) ?? windowManager.displays.first
    }

    private var displayWindows: [ManagedWindow] {
        // With single display, skip filtering (coordinate system differences cause issues)
        guard windowManager.displays.count > 1, let display = selectedDisplay else {
            return orderedWindows
        }
        let displayWindowIds = Set(windowManager.windows(for: display).map(\.id))
        return orderedWindows.filter { displayWindowIds.contains($0.id) }
    }

    /// One order, owned by WindowManager and written only through `setOrder`.
    /// The sidebar renders the same array, so a drag in either place moves the
    /// window in both — and in the arrange slots.
    private var orderedWindows: [ManagedWindow] {
        windowManager.windows
    }

    private var enabledWindows: [ManagedWindow] {
        displayWindows.filter(\.isEnabled)
    }

    private var enabledWindowCount: Int {
        enabledWindows.count
    }

    /// Frames the preview draws and Arrange uses. A window the user dragged to
    /// a size keeps that rect; the rest follow the preset. Without this the
    /// drag-to-resize toggle changed the picture and nothing else.
    private var currentFrames: [NormalizedRect] {
        let preset: [NormalizedRect]
        switch layoutMode {
        case .custom:
            preset = customTemplate.frames(for: enabledWindowCount)
        default:
            preset = LayoutCalculator.calculate(mode: layoutMode, windowCount: enabledWindowCount)
        }

        guard !customFrames.isEmpty else { return preset }
        return enabledWindows.enumerated().map { index, window in
            if let custom = customFrames[window.id] {
                return LayoutResize.clampToDisplay(custom)
            }
            return index < preset.count ? preset[index] : NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    // MARK: - Actions

    private func reorderWindows(from fromIndex: Int, to toIndex: Int) {
        let enabled = enabledWindows
        guard fromIndex >= 0, fromIndex < enabled.count,
              toIndex >= 0, toIndex < enabled.count else { return }

        // One write, one source. This used to swap `customOrder` and the live
        // `windows` array while the views rendered a third list, so a preview
        // drag looked like it did nothing.
        windowManager.swapOrder(enabled[fromIndex].id, with: enabled[toIndex].id)
    }

    private func arrangeWindows() {
        // Target the display the user picked, converted into the top-left
        // origin space the Accessibility API speaks. This used to take
        // `NSScreen.main` — which is the *focused* screen, not the primary —
        // and pin it at (0,0), so arranging while Quip sat on a secondary
        // display threw every window onto the primary at the wrong size.
        guard let display = selectedDisplay else {
            arrangeError = "No display available to arrange on."
            return
        }
        let screenFrame = windowManager.cgFrame(for: display)

        let enabled = enabledWindows
        let frames = currentFrames

        guard !enabled.isEmpty, !frames.isEmpty else {
            arrangeError = enabled.isEmpty
                ? "No windows are enabled — tick one in the sidebar first."
                : "The selected layout produced no frames."
            return
        }

        print("[MainWindow] Arranging \(enabled.count) windows on \(display.name) \(screenFrame)")

        var targetFrames: [String: CGRect] = [:]
        for (index, window) in enabled.enumerated() where index < frames.count {
            let targetRect = frames[index].toCGRect(in: screenFrame)
            targetFrames[window.id] = targetRect
            print("[MainWindow]   \(window.name) -> \(targetRect)")
        }

        // Arrange silently doing nothing is almost always a revoked
        // Accessibility grant. Say so, and offer the one click that fixes it.
        if !windowManager.arrangeWindows(frames: targetFrames) {
            arrangeError = "Quip needs Accessibility access to move windows. Grant it in System Settings → Privacy & Security → Accessibility."
        }
    }
}
