// QuipWatchApp.swift
// QuipWatch — minimal watchOS companion glance for Quip.
// v1 scope: receive per-window Claude state from the iPhone over
// WCSession, render a scroll list, vibrate on attention transitions.
// Complication + send-back actions deferred to v2 (wishlist §53).

import SwiftUI
import WatchKit
import WatchConnectivity

@main
struct QuipWatchApp: App {
    @StateObject private var sync = WatchSync.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sync)
        }
    }
}

/// One row in the watch's window list. Mirrors the iOS WindowState shape
/// but trimmed to the fields the watch actually renders. Decoded from the
/// transferUserInfo dict the iPhone sends on every state change.
struct WatchWindowState: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let state: String      // "thinking" | "neutral" | "waitingForInput"
    let claudeMode: String? // "plan" | "autoAccept" | nil
}

/// Top-level state for the Watch app. Holds the list of windows the iPhone
/// last sent and the most recent attention timestamp. Singleton so the
/// WCSession delegate callbacks (which iOS spawns on background threads)
/// can publish into the same model the SwiftUI view observes.
@MainActor
final class WatchSync: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSync()

    @Published var windows: [WatchWindowState] = []
    /// Wall-clock when the iPhone reported a window flipping to
    /// `waitingForInput`. Used to fire haptics + show a banner.
    @Published var lastAttention: Date?
    @Published var sessionReachable: Bool = false

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.sessionReachable = WCSession.default.isReachable }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.sessionReachable = WCSession.default.isReachable }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        guard let raw = message["windows"] as? Data else { return }
        Task { @MainActor in self.applyWindowsData(raw) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let raw = userInfo["windows"] as? Data else { return }
        Task { @MainActor in self.applyWindowsData(raw) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext appContext: [String: Any]) {
        guard let raw = appContext["windows"] as? Data else { return }
        Task { @MainActor in self.applyWindowsData(raw) }
    }

    @MainActor
    private func applyWindowsData(_ raw: Data) {
        guard let decoded = try? JSONDecoder().decode([WatchWindowState].self, from: raw) else { return }
        let previous = self.windows
        self.windows = decoded

        // Detect any window that just flipped to waitingForInput. Vibrate
        // + bump lastAttention so the UI can banner it.
        let priorState = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.state) })
        for w in decoded {
            if w.state == "waitingForInput", priorState[w.id] != "waitingForInput" {
                self.lastAttention = Date()
                WKInterfaceDevice.current().play(.notification)
                break
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var sync: WatchSync

    var body: some View {
        NavigationStack {
            Group {
                if sync.windows.isEmpty {
                    placeholder
                } else {
                    List(sync.windows) { window in
                        windowRow(window)
                    }
                    .listStyle(.carousel)
                }
            }
            .navigationTitle("Quip")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: sync.sessionReachable
                          ? "iphone.radiowaves.left.and.right"
                          : "iphone.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(sync.sessionReachable ? .green : .secondary)
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Open Quip on iPhone")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    @ViewBuilder
    private func windowRow(_ window: WatchWindowState) -> some View {
        HStack(spacing: 8) {
            stateDot(window.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(stateLabel(window.state) + (window.claudeMode.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private func stateDot(_ state: String) -> some View {
        Circle()
            .fill(stateColor(state))
            .frame(width: 8, height: 8)
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "waitingForInput": return .yellow
        case "thinking": return .blue
        default: return .green
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "waitingForInput": return "Awaiting input"
        case "thinking": return "Thinking…"
        default: return "Idle"
        }
    }
}

#Preview {
    ContentView().environmentObject(WatchSync.shared)
}
