import SwiftUI
import UIKit

/// Shake-to-diagnose sheet. Surfaces an iPhone-side state snapshot the
/// user can copy or share when reporting a Quip issue, plus a button
/// that asks the Mac for its full diagnostics bundle (existing
/// `RequestDiagnosticsMessage` path). Renders on top of the main view
/// when the user shakes their phone (§26).
struct DiagnosticsSheet: View {

    @Environment(\.dismiss) private var dismiss

    /// Pure-string snapshot built once per present. Rendered as a
    /// monospaced selectable block so the user can copy any subset
    /// rather than only the full thing.
    let snapshot: String
    /// Whether the WebSocket is currently authenticated — gates the
    /// "Request Mac bundle" button so we don't fire requests that
    /// will be silently dropped at the auth gate.
    let canRequestMacBundle: Bool
    /// Tap handler for "Request Mac bundle". Caller is responsible
    /// for sending `RequestDiagnosticsMessage` and surfacing the
    /// `diagnostics_bundle` reply (existing path in QuipApp.swift).
    var onRequestMacBundle: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Shake-to-diagnose snapshot")
                        .font(.headline)
                        .padding(.bottom, 4)

                    Text(snapshot)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 8) {
                        Button {
                            UIPasteboard.general.string = snapshot
                            UINotificationFeedbackGenerator()
                                .notificationOccurred(.success)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            onRequestMacBundle()
                        } label: {
                            Label("Request Mac bundle", systemImage: "icloud.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canRequestMacBundle)
                    }

                    if !canRequestMacBundle {
                        Text("Mac bundle requires an authenticated connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("How to use this")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    Text("Copy the snapshot when filing a bug — it captures app version, connection state, paired backends, and the last 30 connection events. The Mac bundle adds server-side logs (websocket.log, push.log, kokoro.log) ZIPped + delivered over the same socket.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Pure formatter for the iPhone-side diagnostics snapshot. Static so
/// it's testable without the SwiftUI view. Output format is a stable
/// human-readable text block — order matters because users grep for
/// specific lines when filing bugs. Keep additions backward-compatible
/// by APPENDING new sections at the bottom rather than reshuffling. (§26.)
enum DiagnosticsSnapshotFormatter {

    struct Input {
        let appVersion: String
        let buildNumber: String
        let isConnected: Bool
        let isConnecting: Bool
        let isAuthenticated: Bool
        let lastError: String?
        let lastDisconnectReason: DisconnectReason?
        let serverURL: String?
        let pairedCount: Int
        let activeBackendName: String?
        let connectionEvents: [String]
    }

    static func format(_ input: Input, now: Date = Date()) -> String {
        let isoFormatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("# Quip iPhone diagnostics — \(isoFormatter.string(from: now))")
        lines.append("App: \(input.appVersion) (\(input.buildNumber))")
        lines.append("")
        lines.append("## Connection")
        lines.append("connected: \(input.isConnected)")
        lines.append("connecting: \(input.isConnecting)")
        lines.append("authenticated: \(input.isAuthenticated)")
        lines.append("serverURL: \(input.serverURL ?? "<none>")")
        lines.append("lastError: \(input.lastError ?? "<none>")")
        lines.append("lastDisconnectReason: \(input.lastDisconnectReason?.tag ?? "<none>")")
        lines.append("")
        lines.append("## Backends")
        lines.append("paired: \(input.pairedCount)")
        lines.append("active: \(input.activeBackendName ?? "<none>")")
        lines.append("")
        lines.append("## Recent connection events (newest last)")
        if input.connectionEvents.isEmpty {
            lines.append("<none>")
        } else {
            lines.append(contentsOf: input.connectionEvents)
        }
        return lines.joined(separator: "\n")
    }
}
